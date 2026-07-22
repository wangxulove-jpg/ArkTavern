import json

with open(r'd:\DevEco_studio\ArkTavern\layout.json', 'r', encoding='utf-8') as f:
    data = json.load(f)

results = []
queue = [data]
while queue:
    node = queue.pop(0)
    if isinstance(node, dict):
        a = node.get('attributes', {})
        t = a.get('type', '')
        b = a.get('bounds', '')
        c = a.get('clickable', '')
        txt = a.get('text', '')
        if t in ('TextArea', 'TextInput') or c == 'true':
            results.append(f'{t} click={c} text="{txt[:30]}" bounds={b}')
        for child in node.get('children', []):
            queue.append(child)

for r in results:
    print(r)
