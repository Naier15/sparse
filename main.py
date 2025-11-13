import logic

print('Start')
k = 100
a = 1 * k
b = 2 * k
c = 3 * k
d = 4 * k
print(a, b, c, d, sep = '\n')

for i in range(5, 10):
    print(i * k)
    
print(logic.rule1 + logic.rule2 + logic.rule3)
print('end')