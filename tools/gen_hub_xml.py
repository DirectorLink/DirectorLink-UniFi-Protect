"""Generate src/hub/driver.xml (the tile icon list is long and mechanical).

    python tools/gen_hub_xml.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRV = "DirectorLink-UniFi-Protect"  # the .c4z file name, used in controller:// icon URLs
STATES = ("on", "alert", "off", "error", "pending")
SIZES = (70, 90, 300, 512, 1024)


def icons(state, ind):
    return "\n".join(f'{ind}<Icon width="{z}" height="{z}">controller://driver/{DRV}/icons/tile/{state}_{z}.png</Icon>' for z in SIZES)


def nav():
    out = ['\t\t<navigator_display_option proxybindingid="5001">', "\t\t\t<display_icons>", icons("on", "\t\t\t\t")]
    for st in STATES:
        out += [f'\t\t\t\t<state id="{st}">', icons(st, "\t\t\t\t\t"), "\t\t\t\t</state>"]
    out += ["\t\t\t</display_icons>", "\t\t</navigator_display_option>"]
    return "\n".join(out)


TEMPLATE = open(os.path.join(ROOT, "tools", "hub_driver.xml.in"), encoding="utf-8").read()


def main():
    xml = TEMPLATE.replace("@@NAVIGATOR_ICONS@@", nav())
    out = os.path.join(ROOT, "src", "hub", "driver.xml")
    open(out, "w", encoding="utf-8", newline="\n").write(xml)
    print("wrote", out)


if __name__ == "__main__":
    main()
