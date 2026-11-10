"""Remove Markup Compatibility and Extensibility content before schema validation.

ECMA-376 Part 3 lets a producer declare namespaces a consumer may ignore
(`mc:Ignorable`) and offer alternatives (`mc:AlternateContent`). The ECMA-376
Part 4 schemas predate every such extension, so a part is validated after the
ignorable content is removed and each alternative is resolved the way a
consumer that understands only the schema namespaces would resolve it.

This is an oracle adapter: an independent implementation of the Part 3 rules
that must not import package code. Prefix declarations are collected for the
whole document, so a prefix rebound to a different namespace inside the part
would be misread; no mainstream producer does that.
"""

import sys
import xml.etree.ElementTree as ET

MC = "http://schemas.openxmlformats.org/markup-compatibility/2006"

# Namespaces the ECMA-376 Transitional schemas define: a Choice that requires
# only these is one the schema-level consumer can take.
UNDERSTOOD = {
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "http://schemas.openxmlformats.org/officeDocument/2006/math",
    "http://schemas.openxmlformats.org/officeDocument/2006/sharedTypes",
    "http://schemas.openxmlformats.org/drawingml/2006/main",
    "http://schemas.openxmlformats.org/drawingml/2006/picture",
    "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    "http://schemas.openxmlformats.org/drawingml/2006/chart",
    "http://schemas.openxmlformats.org/drawingml/2006/diagram",
    "http://schemas.openxmlformats.org/drawingml/2006/lockedCanvas",
    "http://schemas.openxmlformats.org/schemaLibrary/2006/main",
    "urn:schemas-microsoft-com:vml",
    "urn:schemas-microsoft-com:office:office",
    "urn:schemas-microsoft-com:office:word",
    "http://www.w3.org/XML/1998/namespace",
}


def namespace_of(name):
    return name[1:name.index("}")] if name.startswith("{") else ""


def prefix_map(path):
    prefixes = {}
    for _event, (prefix, uri) in ET.iterparse(path, events=("start-ns",)):
        prefixes.setdefault(prefix, uri)
    return prefixes


def strip(path, out_path):
    """Write `path` to `out_path` with ignorable content removed. Returns the
    namespaces that were declared ignorable, for reporting."""
    prefixes = prefix_map(path)
    tree = ET.parse(path)
    root = tree.getroot()
    ignorable_seen = set()

    def resolve(prefix_list):
        return {prefixes[p] for p in prefix_list.split() if p in prefixes}

    def process(element, ignorable):
        declared = element.get(f"{{{MC}}}Ignorable")
        if declared:
            ignorable = ignorable | resolve(declared)
            ignorable_seen.update(ignorable)
        for key in list(element.attrib):
            ns = namespace_of(key)
            if ns == MC or ns in ignorable:
                del element.attrib[key]
        new_children = []
        for child in list(element):
            if child.tag == f"{{{MC}}}AlternateContent":
                new_children.extend(select_alternative(child, ignorable))
            elif namespace_of(child.tag) in ignorable and namespace_of(child.tag) not in UNDERSTOOD:
                continue
            else:
                process(child, ignorable)
                new_children.append(child)
        element[:] = new_children

    def select_alternative(alternate, ignorable):
        chosen = None
        for branch in alternate:
            if branch.tag == f"{{{MC}}}Choice":
                requires = resolve(branch.get("Requires", ""))
                if requires and requires <= UNDERSTOOD:
                    chosen = branch
                    break
            elif branch.tag == f"{{{MC}}}Fallback" and chosen is None:
                chosen = branch
        if chosen is None:
            return []
        for child in chosen:
            process(child, ignorable)
        return list(chosen)

    process(root, set())
    for prefix, uri in prefixes.items():
        if prefix:
            try:
                ET.register_namespace(prefix, uri)
            except ValueError:
                pass  # a producer used a prefix ElementTree reserves; it is renamed, which validation ignores
    tree.write(out_path, xml_declaration=True, encoding="UTF-8")
    return ignorable_seen


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: mce_strip.py INPUT.xml OUTPUT.xml")
    removed = strip(sys.argv[1], sys.argv[2])
    for ns in sorted(removed):
        print(f"ignorable: {ns}")
