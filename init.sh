#!/bin/bash
work_dir=$(pwd)
cd "$work_dir"
git config --global fetch.prune true
git config --global alias.sc 'sparse-checkout'
git config --global alias.lg 'log --all --graph --oneline'
git config --global alias.spa '!f() { case "$1" in "run") ./scripts/sparse.sh 1 ;; "stop") ./scripts/sparse.sh 3 ;; "") ./scripts/sparse.sh 2 ;; *) echo "Wrong parameter: $1" ;; esac }; f'

connect_git() {
	if [ -d "$work_dir"/.git ]; then
		echo -e "Git репозиторий уже существует\nЕсли хотите подключиться заново удалите папку .git и перезапустите ./init.sh"
		return 0
	fi

	echo "-- Алло! Вы готовы? --"
		
	git init
	git config --global push.autoSetupRemote true
	git config --global --add safe.directory "$work_dir"

	while [ 1 ]
	do
		read -p "Подключить к IBSO или CRM (1/2): " system

		if [ "$system" = "1" ]; then
			echo "Подключено к IBSO"
			git remote add origin git@vld-srvgit01.pskb.ad:dev/IBSO.git
			break
		elif [ "$system" = "2" ]; then
			echo "Подключено к CRM"
			git remote add origin git@vld-srvgit01.pskb.ad:dev/crm.git
			break
		else
			echo "Пожалуйста, введите номер варианта (1/2)"
		fi
	done

	echo ".dbobjects
.model
.project
.settings
imports.pck
imports_db.pck
platform.project
/scripts
/update_main.sh
/macro.cache
/modified.info
/META-INF
.gitignore
/src-gen
TESTING*
init.sh
log.txt
" > .gitignore

	while [ 1 ]
	do
		read -p "Сгенерировать новый SSH ключ? (y/n) " generate_ssh
		if [ "$generate_ssh" = "y" ]; then
		
			echo -ne "\n" | ssh-keygen -t ed25519
			echo -ne "\n\n"

			while [ 1 ]
			do
				read -p "Выполните следующие шаги:
	1. Скопируйте публичный ssh ключ C:/Пользователи/Пользователь/.ssh/id_ed25519.pub
	2. Вставьте его в Gitlab > Preferences > SSH Keys > Add new key
	Но! При добавлении нового ключа отчистите поле Expiration date
	3. Для продолжения введите команду done : " continue

				if [ "$continue" = "done" ]; then
					break
				fi
			done

			break
		elif [ "$generate_ssh" = "n" ]; then
			break
		fi
	done

	git fetch origin
	git sparse-checkout init --no-cone
	git switch main
}

generate_scripts() {	
	# Генерация скриптов
	if [ -d "$work_dir"/scripts ]; then
		while [ 1 ]
		do
			read -p "Обновить скрипты? (y/n) " answer
			if [ "$answer" = "n" ]; then
				return 0
			elif [ "$answer" = "y" ]; then
				break
			fi
		done
	else
		mkdir "$work_dir"/scripts
	fi
	
	rm -f ./.git/info/proc_id
	rm -f ./.git/info/merge
	rm -f ./.git/hooks/update.sh
	rm -f ./.git/hooks/post-checkout
	rm -f ./.git/hooks/post-switch.sh
	rm -f ./scripts/tree-graph.sh
	rm -f ./scripts/sparse-checkout.sh
	rm -f ./scripts/graph.sh

	echo '
param(
    [Alias("l")]
    [switch] $log
)

$ErrorActionPreference = "Stop"

function find_repo_root([string] $start) {
    $dir = Get-Item -LiteralPath $start
    while ($null -ne $dir) {
        if ($dir.Name -eq ".git") {
            return $dir.Parent.FullName
        }

        $gitMeta = Join-Path $dir.FullName ".git"
        $full = $dir.FullName
        $insideDotGit = $full -match "[\\/]\.git([\\/]|$)"
        if (-not $insideDotGit -and (Test-Path -LiteralPath $gitMeta)) {
            return $full
        }

        $dir = $dir.Parent
    }
    return $null
}

$root = find_repo_root $PSScriptRoot
if (-not $root) {
    Write-Error "Cannot find git repository root from $PSScriptRoot"
    exit 1
}
Set-Location -LiteralPath $root

$src_root = "src"
$source_branch = "main"
$info = Join-Path $root ".git/info"
$snapshot = Join-Path $info "snapshot"
$token_file = Join-Path $info "token"
$branch_file = Join-Path $info "branch"
$pid_file = Join-Path $info "update.pid"
$stop_file = Join-Path $info "update.stop"
$log_file = Join-Path $root "log.txt"

$latency_ms = 1000
$suppress_sec = 1.0

# Shared with FileSystemWatcher event runspaces
$state = [hashtable]::Synchronized(@{
    last_token     = ""
    last_branch    = ""
    last_head      = ""
    last_disk_sig  = ""
    suppress_until = [datetime]::MinValue
    pending        = $true
    do_log         = [bool]$log
})

function log([string] $message) {
    if (-not $state.do_log) { return }
    $line = "{0:dd.MM.yyyy HH:mm:ss} | {1}" -f (Get-Date), $message
    Add-Content -Path $log_file -Value $line -Encoding utf8
}

function read_text_file([string] $path) {
    if (-not (Test-Path $path)) { return "" }
    $raw = Get-Content -Path $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return "" }
    return $raw.Trim()
}

function write_text_file([string] $path, [string] $text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $text)
}

function convert_to_posix([string] $path) {
    return ($path -replace "\\", "/")
}

# src/main.py → src/main*
function to_sparse_pattern([string] $path) {
    $path = convert_to_posix $path
    if ($path -match "\.[^./]+$") {
        return ($path -replace "\.[^./]+$", ".*")
    }
    return $path
}

function invoke_git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $git_args)
    $out = & git -C $root @git_args 2>&1
    return [pscustomobject]@{
        exit_code = $LASTEXITCODE
        output    = @($out | ForEach-Object { "$_" }) -join "`n"
    }
}

function test_git_busy {
    return (Test-Path (Join-Path $root ".git/index.lock")) -or
           (Test-Path (Join-Path $root ".git/HEAD.lock"))
}

function get_current_branch {
    return (invoke_git "branch" "--show-current").output.Trim()
}

function get_rev_parse([string] $ref = "HEAD") {
    return (invoke_git "rev-parse" $ref).output.Trim()
}

# Cheap signal: names under src/ (no git). Used to skip heavy sync.
function get_disk_sig {
    $src = Join-Path $root $src_root
    if (-not (Test-Path -LiteralPath $src)) { return "" }
    $names = Get-ChildItem -LiteralPath $src -File -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName + "|" + $_.Length + "|" + $_.LastWriteTimeUtc.Ticks } |
        Sort-Object
    return get_sha256 (($names -join "`n"))
}

function update_snapshot([string] $branch) {
    $result = invoke_git "diff" "--name-only" "$source_branch...$branch"
    $paths = @(
        $result.output -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            ForEach-Object { to_sparse_pattern $_ } |
            Sort-Object -Unique
    )
    write_text_file $snapshot (($paths -join "`n") + "`n")
}

function get_src_files {
    $src = Join-Path $root $src_root
    if (-not (Test-Path -LiteralPath $src)) { return @() }

    $root_full = [System.IO.Path]::GetFullPath($root).TrimEnd("\", "/")
    $all = New-Object System.Collections.Generic.List[string]

    Get-ChildItem -LiteralPath $src -File -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        ForEach-Object {
            if ($null -eq $_ -or [string]::IsNullOrEmpty($_.FullName)) { return }
            $full = [System.IO.Path]::GetFullPath($_.FullName)
            if ($full.Length -le $root_full.Length) { return }
            $rel = convert_to_posix ($full.Substring($root_full.Length).TrimStart("\", "/"))
            if (-not [string]::IsNullOrEmpty($rel)) {
                [void]$all.Add($rel)
            }
        }

    if ($all.Count -eq 0) { return @() }

    $ignored = New-Object System.Collections.Generic.HashSet[string]
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = "-C `"$root`" check-ignore --stdin"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    foreach ($rel in $all) {
        $proc.StandardInput.WriteLine($rel)
    }
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    foreach ($line in ($out -split "`r?`n")) {
        $line = convert_to_posix ($line.Trim())
        if ($line) { [void]$ignored.Add($line) }
    }

    $patterns = foreach ($rel in $all) {
        if (-not $ignored.Contains($rel)) {
            to_sparse_pattern $rel
        }
    }
    return @($patterns | Sort-Object -Unique)
}

function get_sha256([string] $text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function set_sparse_checkout([string[]] $files) {
    $cleaned_files = @($files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    $payload = @("null") + $cleaned_files
    $text = ($payload -join "`n") + "`n"
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = "-C `"$root`" sparse-checkout set --stdin"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($text)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
}

function test_pid_alive([int] $process_id) {
    if ($process_id -le 0) { return $false }
    try {
        $null = Get-Process -Id $process_id -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function get_already_running {
    if (-not (Test-Path $pid_file)) { return $null }
    $raw = read_text_file $pid_file
    $proc_id = 0
    if (-not [int]::TryParse($raw, [ref]$proc_id)) { return $null }
    if ($proc_id -eq $PID) { return $null }
    if (test_pid_alive $proc_id) { return $proc_id }
    return $null
}

function invoke_sync {
    if ([datetime]::UtcNow -lt $state.suppress_until) { return }
    if (test_git_busy) {
        Start-Sleep -Milliseconds 300
        if (test_git_busy) { return }
    }

    $branch = get_current_branch
    if (-not $branch) { return }
    $head = get_rev_parse
    if (-not $head) { return }
    $git_state_changed = $false

    if ($branch -ne $state.last_branch -or $head -ne $state.last_head) {
        log "-- Current branch: $branch --"
        
        # Шаг 1. Пересчитываем snapshot (дифф с main...текущая_ветка)
        update_snapshot $branch
        
        # Шаг 2. Обновляем файлы состояния на диске
        write_text_file $branch_file $branch
        
        $state.last_branch = $branch
        $state.last_head = $head
        $git_state_changed = $true
    }

    # Шаг 3. Читаем snapshot (разницу с main), созданный на Шаге 1
    $snap = @()
    if (Test-Path $snapshot) {
        $snap = @(
            Get-Content $snapshot -ErrorAction SilentlyContinue |
                ForEach-Object { to_sparse_pattern $_.Trim() } |
                Where-Object { $_ }
        )
    }
    log "SNAP $snap"

    # Шаг 4. Собираем локальные файлы из src/
    # Если ветка изменилась, полностью игнорируем старый диск
    if ($git_state_changed) {
        $disk = @()
    } else {
        $disk = @(get_src_files)
    }
    log "DISK: $disk"

    # Шаг 5. Объединяем разницу веток и физические файлы на диске
    $files = @($snap + $disk | Sort-Object -Unique)

    # Шаг 6. Считаем токен результирующего набора паттернов
    $token = get_sha256 ($files -join "`n")
    
    if ($token -eq $state.last_token -and -not $git_state_changed) { return }

    # Шаг 7. Применяем конфигурацию в Git
    log ("Patterns: " + ($files -join " "))
    $state.suppress_until = [datetime]::UtcNow.AddSeconds($suppress_sec)
    set_sparse_checkout $files
    
    write_text_file $token_file $token
    $state.last_token = $token
	$state.last_disk_sig = get_disk_sig
	New-Item -ItemType Directory -Force -Path (Join-Path $root $src_root) | Out-Null
    log "-- Updated successfully --"
}


function register_watch([string] $path, [bool] $recursive) {
    if (-not (Test-Path $path)) { return $null }
    $watcher = New-Object System.IO.FileSystemWatcher -Property @{
        Path = (Resolve-Path $path).Path
        IncludeSubdirectories = $recursive
        NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
        EnableRaisingEvents = $true
    }

    $subscribers = foreach ($evt in @("Created", "Changed", "Deleted", "Renamed")) {
        Register-ObjectEvent -InputObject $watcher -EventName $evt -SourceIdentifier "${evt}_$([Guid]::NewGuid())"
    }
    return [pscustomobject]@{ watcher = $watcher; subscribers = $subscribers }
}

# -- main --
$null = New-Item -ItemType Directory -Force -Path $info
$null = New-Item -ItemType Directory -Force -Path (Join-Path $root $src_root)

if (-not (get_current_branch)) {
    Write-Error "Not on a git branch (detached HEAD or not a repo): $root"
    exit 1
}

$other = get_already_running
if ($null -ne $other) {
    write_text_file $pid_file "$other"
    [Console]::Out.WriteLine("-- WORKING (PID: $other) --") # Убрано дублирование в Error stream
    exit 0
}

if (Test-Path -LiteralPath $stop_file) {
    Remove-Item -LiteralPath $stop_file -Force -ErrorAction SilentlyContinue
}

write_text_file $pid_file "$PID"
$watches = @()

try {
    $state.last_branch = read_text_file $branch_file
    $state.last_head = get_rev_parse
	$state.last_token = ""

    log "-- SPARSE START --"
    log "Watch: $(Join-Path $root $src_root)"

    # Регистрация вотчеров
    $watches += register_watch (Join-Path $root $src_root) $true
    $state.last_disk_sig = get_disk_sig

    $skip_files = [System.Collections.Generic.HashSet[string]]::new([string[]]@("update.pid", "update.stop", "token", "snapshot", "branch", "sparse-checkout"), [System.StringComparer]::OrdinalIgnoreCase)

    while ($true) {
        if (Test-Path -LiteralPath $stop_file) {
            log "-- STOP REQUESTED --"
            break
        }

        Start-Sleep -Milliseconds $latency_ms

        if (Test-Path -LiteralPath $stop_file) {
            log "-- STOP REQUESTED --"
            break
        }

        # Читаем события из очереди PowerShell
        $events = Get-Event -ErrorAction SilentlyContinue
        if ($events) {
			log "---- events start ----"
            foreach ($evt in $events) {
				# Если флаг уже взведен, просто быстро очищаем оставшуюся очередь и выходим из foreach
                if ($state.pending) {
                    Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
                    continue
                }
				
                $name = $evt.SourceEventArgs.Name
				log "--> $name"
                if ($name) {
                    $ext = [System.IO.Path]::GetExtension($name)
					
                    # Фильтрация временных файлов и логов
                    if (-not $skip_files.Contains([System.IO.Path]::GetFileName($name)) -and 
                        $name -notlike "~*") {
                        $state.pending = $true
                    }
                } else {
                    $state.pending = $true
                }
                Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            }
			log "---- events finish ----"
			log "SYSTEM UPDATE: $($state.pending)"
        }

        # Быстрая проверка изменений на диске
		if (-not $state.pending) {
			$disk_sig = get_disk_sig
			if ($disk_sig -ne $state.last_disk_sig) {
				log "DISK UPDATE: true"
				$state.last_disk_sig = $disk_sig
				$state.pending = $true
			}
		}

        # Проверка смены коммита по хэшу
		if (-not $state.pending) {
			$current_head = get_rev_parse
			if ($current_head -and $current_head -ne $state.last_head) {
				log "COMMIT CHANGED"
				$state.pending = $true
			}
		}

        if ($state.pending) {
            $state.pending = $false
            invoke_sync
        }
    }
}
finally {
    foreach ($watch in $watches) {
        if (-not $watch) { continue }
        foreach ($sub in $watch.subscribers) {
            Unregister-Event -SourceIdentifier $sub.SourceIdentifier -ErrorAction SilentlyContinue
        }
        if ($watch.watcher) {
            $watch.watcher.EnableRaisingEvents = $false
            $watch.watcher.Dispose()
        }
    }
    if ((Test-Path $pid_file) -and ((read_text_file $pid_file) -eq "$PID")) {
        Remove-Item $pid_file -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stop_file) {
        Remove-Item -LiteralPath $stop_file -Force -ErrorAction SilentlyContinue
    }
}
' > ./.git/hooks/sparse_daemon.ps1

	echo '#!/bin/bash
work_dir="'$work_dir'"
cd "$work_dir"
echo "Welcome"
git branch -v
exec bash' > ./scripts/console.sh

	echo '#!/bin/bash
WORK_DIR="'$work_dir'"
DAEMON="$WORK_DIR/.git/hooks/sparse_daemon.ps1"
PID_FILE="$WORK_DIR/.git/info/update.pid"
LOG_FILE="$WORK_DIR/log.txt"
START_ERR="$WORK_DIR/.git/info/daemon.err"
STOP_FILE="$WORK_DIR/.git/info/update.stop"

cd "$WORK_DIR" || { echo "[ERROR] Directory not found: $WORK_DIR"; exit 1; }

if [[ ! -f "$DAEMON" ]]; then
    echo "[ERROR] Sparse daemon not found: $DAEMON"
    exit 1
fi

resolve_powershell() {
    command -v pwsh || command -v powershell.exe || echo ""
}

pid_alive() {
    local pid=$1
    [[ -z "$pid" || "$pid" == "0" ]] && return 1
    kill -0 "$pid" 2>/dev/null && return 0
    
    if command -v tasklist.exe >/dev/null 2>&1; then
        tasklist.exe //FI "PID eq $pid" 2>/dev/null | grep -q "$pid"
        return $?
    fi
    return 1
}

read_pid_file() {
    [[ -f "$PID_FILE" ]] && tr -cd '0-9' < "$PID_FILE" 2>/dev/null
}

get_status() {
    local pid
    pid=$(read_pid_file)
    if [[ -n "$pid" ]] && pid_alive "$pid"; then
        echo "$pid"
        return 0
    fi
    rm -f "$PID_FILE"
    echo ""
}

wait_gone() {
    local pid=$1
    local n=$2
    local i
    for i in $(seq 1 "$n"); do
        pid_alive "$pid" || return 0
        sleep 0.2
    done
    pid_alive "$pid" && return 1
    return 0
}

kill_pid() {
    local pid=$1
    local force=$2
    if [[ "$force" != "1" ]]; then
        kill -TERM "$pid" 2>/dev/null && return 0
        if command -v taskkill.exe >/dev/null 2>&1; then
            taskkill.exe //PID "$pid" >/dev/null 2>&1 && return 0
        fi
        return 1
    fi
    kill -KILL "$pid" 2>/dev/null && return 0
    if command -v taskkill.exe >/dev/null 2>&1; then
        taskkill.exe //PID "$pid" //T //F >/dev/null 2>&1 && return 0
    fi
    return 1
}

stop_daemon() {
    local pid
    pid=$(get_status)
    if [[ -z "$pid" ]]; then
        rm -f "$PID_FILE" "$STOP_FILE"
        return 0
    fi

    # 1) Ask the daemon to exit the loop so finally disposes FileSystemWatcher
    : > "$STOP_FILE"
    if wait_gone "$pid" 25; then
        echo "Process $pid stopped"
        rm -f "$PID_FILE" "$STOP_FILE"
        return 0
    fi

    # 2) SIGTERM / taskkill without /F
    kill_pid "$pid" 0
    if wait_gone "$pid" 15; then
        echo "Process $pid stopped"
        rm -f "$PID_FILE" "$STOP_FILE"
        return 0
    fi

    # 3) SIGKILL / taskkill /T /F (process tree)
    kill_pid "$pid" 1
    if wait_gone "$pid" 10; then
        echo "Process $pid stopped"
        rm -f "$PID_FILE" "$STOP_FILE"
        return 0
    fi

    echo "Failed to stop process $pid"
    return 1
}

start_daemon() {
    local with_log=$1
    local ps_bin args=()
    local pid

    pid=$(get_status)
    if [[ -n "$pid" ]]; then
        echo "-- WORKING (PID: $pid) --"
        return 0
    fi

    ps_bin=$(resolve_powershell)
    if [[ -z "$ps_bin" ]]; then
        echo "[ERROR] PowerShell not found"
        return 1
    fi

    [[ "$with_log" == "1" ]] && args+=(-Log)

    rm -f "$PID_FILE" "$STOP_FILE"
    : > "$START_ERR"

    nohup "$ps_bin" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DAEMON" "${args[@]}" >"$START_ERR" 2>&1 &

    local i
    for i in {1..15}; do
        sleep 0.2
        pid=$(get_status)
        [[ -n "$pid" ]] && break
    done

    if [[ -n "$pid" ]]; then
        echo "-- WORKING (PID: $pid) --"
        [[ "$with_log" == "1" ]] && echo "Log enabled"
        rm -f "$START_ERR"
        return 0
    fi

    if [[ -s "$START_ERR" ]]; then
        echo "---- [ERROR] Sparse daemon failed ----"
        cat "$START_ERR"
        echo "---------------------------"
    fi
    return 1
}

run_option() {
    case "$1" in
        1) start_daemon 0 ;;
        0) start_daemon 1 ;;
        2) 
            pid=$(get_status)
            if [[ -n "$pid" ]]; then 
                echo "-- WORKING (PID: $pid) --"
            else 
                echo "-- STOPPED --"
            fi 
            ;;
        3) 
            if stop_daemon; then
                echo "-- STOPPED --"
            else
                echo "-- STILL WORKING --"
            fi
            ;;
        [QqЙй]) 
            exit 0 
            ;;
        *) 
            echo "Ошибка: введите 0, 1, 2, 3 или Q" 
            if [[ -n "$LAUNCHED_WITH_ARG" ]]; then exit 1; fi
            ;;
    esac
}

if [[ -n "$1" ]]; then
    LAUNCHED_WITH_ARG=true
    run_option "$1"
    exit 0
fi

echo "-- Управление Sparse Checkout --"
echo "1. Включить"
echo "2. Состояние"
echo "3. Выключить"
echo "Q. Выход"

while true; do
    read -r -p ">> " option
    run_option "$option"
done
' > ./scripts/sparse.sh

	echo "Скрипты обновлены"
}

echo "------------------------------------------------"
connect_git
echo "------------------------------------------------"
generate_scripts
echo "------------------------------------------------"

while [ 1 ]
do
	read -p "Удалить init.sh? (y/n) " to_delete

	if [ "$to_delete" = "y" ]; then
		rm ./init.sh
		break
	elif [ "$to_delete" = "n" ]; then
		break
	else
		echo "Пожалуйста, введите y или n:"
	fi
done