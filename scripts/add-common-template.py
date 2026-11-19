#!/usr/bin/env python3
"""Adds a text common template (общий макет) to an extension in XML sources.

The skill template-add can't do it: it adds templates owned by an object. A common template is
  <ext>/CommonTemplates/<name>.xml                 the metadata (a new uuid);
  <ext>/CommonTemplates/<name>/Ext/Template.txt    the text, UTF-8 with one BOM; created empty if absent;
  <ext>/Configuration.xml                          <CommonTemplate><name></CommonTemplate> in ChildObjects,
                                                   after the last common template (the first one goes before
                                                   the first common module).
Usage: python scripts/add-common-template.py <extension dir> <name> [synonym]
Exit codes: 0 — added, 1 — the template already exists or the structure is not as expected.
The recording scripts (b24-record-responses.sh, openai-record-responses.sh) fill Template.txt afterwards.
"""
import os
import re
import sys
import uuid

BOM = b"\xef\xbb\xbf"

HEADER = (
    '<?xml version="1.0" encoding="UTF-8"?>{nl}'
    '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
    'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
    'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
    'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
    'xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
    'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
    'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
    'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.16">{nl}'
)

BODY = (
    "\t<CommonTemplate uuid=\"{uuid}\">{nl}"
    "\t\t<Properties>{nl}"
    "\t\t\t<Name>{name}</Name>{nl}"
    "\t\t\t<Synonym>{nl}"
    "\t\t\t\t<v8:item>{nl}"
    "\t\t\t\t\t<v8:lang>ru</v8:lang>{nl}"
    "\t\t\t\t\t<v8:content>{synonym}</v8:content>{nl}"
    "\t\t\t\t</v8:item>{nl}"
    "\t\t\t</Synonym>{nl}"
    "\t\t\t<Comment/>{nl}"
    "\t\t\t<TemplateType>TextDocument</TemplateType>{nl}"
    "\t\t</Properties>{nl}"
    "\t</CommonTemplate>{nl}"
    "</MetaDataObject>"
)


def escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def add(extension_dir, name, synonym):
    if not re.fullmatch(r"[A-Za-zА-Яа-яЁё_][A-Za-zА-Яа-яЁё_0-9]*", name):
        print("Недопустимое имя макета: %s" % name, file=sys.stderr)
        return 1
    configuration = os.path.join(extension_dir, "Configuration.xml")
    templates = os.path.join(extension_dir, "CommonTemplates")
    metadata = os.path.join(templates, name + ".xml")
    if os.path.exists(metadata):
        print("Макет уже есть: %s" % name, file=sys.stderr)
        return 1

    raw = open(configuration, "rb").read()
    text = raw.decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in text else "\n"
    if "<CommonTemplate>%s</CommonTemplate>" % name in text:
        print("Макет уже записан в Configuration.xml: %s" % name, file=sys.stderr)
        return 1
    lines = text.split(newline)
    last = max((i for i, line in enumerate(lines) if line.strip().startswith("<CommonTemplate>")), default=None)
    if last is not None:
        position = last + 1
    else:
        # The first template of the extension: the platform keeps templates before the common modules.
        first_module = next((i for i, line in enumerate(lines) if line.strip().startswith("<CommonModule>")), None)
        if first_module is None:
            print("В Configuration.xml нет ни общих макетов, ни общих модулей: добавьте первый макет вручную.",
                  file=sys.stderr)
            return 1
        last, position = first_module, first_module
    indent = lines[last][: len(lines[last]) - len(lines[last].lstrip())]
    lines.insert(position, "%s<CommonTemplate>%s</CommonTemplate>" % (indent, name))
    with open(configuration, "wb") as handle:
        handle.write((BOM if raw.startswith(BOM) else b"") + newline.join(lines).encode("utf-8"))

    os.makedirs(os.path.join(templates, name, "Ext"), exist_ok=True)
    xml = (HEADER + BODY).format(nl=newline, uuid=uuid.uuid4(), name=name, synonym=escape(synonym))
    with open(metadata, "wb") as handle:
        handle.write(BOM + xml.encode("utf-8"))
    body = os.path.join(templates, name, "Ext", "Template.txt")
    if not os.path.exists(body):
        with open(body, "wb") as handle:
            handle.write(BOM)
    print("Добавлен макет %s" % name)
    return 0


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 1
    synonym = argv[2] if len(argv) == 3 else argv[1]
    return add(argv[0], argv[1], synonym)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
