import sys
import importlib.util

mods = set(sys.builtin_module_names)
mods.update(sys.modules.keys())

for name in sorted(mods):
    try:
        spec = importlib.util.find_spec(name)
        if spec:
            print(f"{name}: {spec.origin}")
    except Exception as e:
        print(f"{name}: ❌ {e}")
