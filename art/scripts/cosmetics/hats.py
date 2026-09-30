r"""Build all hat GLBs -> game/assets/models/cosmetics/hat_<id>.glb

Run: powershell -File tools\blender-run.ps1 art\scripts\cosmetics\hats.py [-- --only=top_hat,crown]
Geometry helpers live in hats_lib.py, the designs in hats_a.py (top_hat, party_cone, crown, wizard,
cowboy, chef) and hats_b.py (propeller_cap, pirate, viking, flower_pot, traffic_cone, cat_ears).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artlib  # noqa: E402
import hats_lib as H  # noqa: E402
import hats_a  # noqa: E402,F401
import hats_b  # noqa: E402,F401

TRI_MIN, TRI_MAX = 300, 1500


def main():
    only = None
    for a in artlib.script_args():
        if a.startswith("--only="):
            only = a[len("--only="):].split(",")
    failed = []
    for hat_id, fn in H.HATS.items():
        if only and hat_id not in only:
            continue
        H.reset()
        res = fn()
        builder, extra = (res if isinstance(res, tuple) else (res, {}))
        obj = builder.to_object("Hat")
        tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
        parts = {"Hat": tris}
        for name, (sb, loc) in extra.items():
            so = sb.to_object(name, loc)
            parts[name] = sum(len(p.vertices) - 2 for p in so.data.polygons)
        total = sum(parts.values())
        print(f"HAT {hat_id}: {total} tris {parts}")
        H.check_fit(obj, hat_id)
        if not (TRI_MIN <= total <= TRI_MAX):
            failed.append(f"{hat_id}: {total} tris outside {TRI_MIN}-{TRI_MAX}")
        artlib.export_glb(f"hat_{hat_id}", family="cosmetics")
    if failed:
        raise RuntimeError("triangle budget: " + "; ".join(failed))


main()
