from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path
import struct
from zipfile import ZIP_DEFLATED, ZipFile


NEWS = "gamedata/scripts/dynamic_news_manager.script"
ENGINE = (
    "xrAICore.dll", "xrEngine.dll", "xrGame.dll", "xrGameSpy.dll",
    "xrNetServer.dll", "xrRender_R4.dll", "xrSound.dll", "xrUICore.dll",
)
REQUIRED_DATA = (
    "gamedata/configs/misc/items/iwp_pda.ltx",
    "gamedata/configs/plugins/new_game_start_locations.ltx",
    "gamedata/scripts/slot_hud.script",
    "gamedata/shaders/r3/models_pda_indicator.ps",
)
NEWS_EDITS = (
    (
        'elseif (self.response["type"] == "loot") and (self.response["who"]) and (#self.loot > 0) then\n'
        '\t\tself:GossipLoot(self.response["who"],self:GetLootBestItem(self.loot),self:GetLootValue(self.loot))',
        'elseif (self.response["type"] == "loot") and self.loot_sender and (#self.loot > 0) then\n'
        '\t\tself:GossipLoot(self.loot_sender,self:GetLootBestItem(self.loot),self:GetLootValue(self.loot))\n'
        '\t\tself.loot_sender = nil',
    ),
    (
        'table.insert(self.loot,item)\n\tself.response["who"] = npc',
        '-- The deferred reaction may run after the NPC or item has despawned.\n'
        '\ttable.insert(self.loot,{cost = item:cost(), section = item:section()})\n'
        '\tself.loot_sender = {\n'
        '\t\tname = strformat("%s, %s",npc:character_name(),dynamic_news_helper.GetCommunityDescription(npc,6)),\n'
        '\t\ticon = npc:character_icon()\n'
        '\t}\n'
        '\tself.response["who"] = nil',
    ),
    ('value = value + item_tbl[i]:cost()', 'value = value + item_tbl[i].cost'),
    (
        'item_tbl[i]:cost() > value then\n\t\t\tvalue = item_tbl[i]:cost()',
        'item_tbl[i].cost > value then\n\t\t\tvalue = item_tbl[i].cost',
    ),
    ('ini:r_string_ex(best_item:section(),"inv_name")', 'ini:r_string_ex(best_item.section,"inv_name")'),
    (
        'local Se = strformat("%s, %s",sender:character_name(),dynamic_news_helper.GetCommunityDescription(sender,6))\n\t\n'
        '\tself.response["message"] = {Mg=msg,Ic=sender:character_icon(),Snd="beep_1",Se=Se,It="npc",To=false,St=msg_duration}',
        'self.response["message"] = {Mg=msg,Ic=sender.icon,Snd="beep_1",Se=sender.name,It="npc",To=false,St=msg_duration}',
    ),
)


def build_news_patch(original):
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    edits = []
    for old, new in NEWS_EDITS:
        find = old.encode().replace(b"\n", newline)
        if original.count(find) != 1:
            raise ValueError(f"Expected one match for {old[:80]!r}")
        edits.append((original.index(find), len(find), new.encode().replace(b"\n", newline)))
    patched = bytearray()
    records = bytearray()
    cursor = 0
    for offset, size, replacement in sorted(edits):
        if offset < cursor:
            raise ValueError("Overlapping edits")
        patched.extend(original[cursor:offset])
        patched.extend(replacement)
        records.extend(struct.pack("<iii", offset, size, len(replacement)))
        records.extend(replacement)
        cursor = offset + size
    patched.extend(original[cursor:])
    return bytes(patched), bytes(records)


def digest(data):
    return sha256(data).hexdigest()


def main():
    parser = ArgumentParser(description="Build the embedded XR64 update payload from a verified local runtime.")
    parser.add_argument("runtime", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--write-patched-news", type=Path)
    args = parser.parse_args()

    license_path = Path(__file__).resolve().parents[2] / "License.txt"
    original = (args.runtime / NEWS).read_bytes()
    patched, records = build_news_patch(original)
    if args.write_patched_news:
        args.write_patched_news.write_bytes(patched)

    with ZipFile(args.output, "w", compression=ZIP_DEFLATED, compresslevel=6) as archive:
        manifest = []
        for path in REQUIRED_DATA:
            manifest.append(f"require\t{path}\t{digest((args.runtime / path).read_bytes())}")
        for name in ENGINE:
            path = f"bin/{name}"
            data = (args.runtime / path).read_bytes()
            archive.writestr(path, data)
            manifest.append(f"file\t{path}\t{digest(data)}")
        archive.write(license_path, "OpenXRay-License.txt")
        manifest.append(f"file\tOpenXRay-License.txt\t{digest(license_path.read_bytes())}")
        launch = b'@echo off\r\ncd /d "%~dp0"\r\nstart "" "bin\\xrEngine.exe" -nosplash -nointro\r\n'
        archive.writestr("Play XR64.cmd", launch)
        manifest.append(f"file\tPlay XR64.cmd\t{digest(launch)}")
        archive.writestr("patches/news.bin", records)
        manifest.append(f"patch\t{NEWS}\t{digest(patched)}\t{digest(original)}\tpatches/news.bin")
        archive.writestr("manifest.tsv", "\n".join(manifest) + "\n")


if __name__ == "__main__":
    main()
