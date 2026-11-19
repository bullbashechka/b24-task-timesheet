#!/usr/bin/env python3
"""Reads the export of the register «ГЕМ Шаблоны для заполнения табелей» and prepares the material for the AI stages.

Usage:
  python scripts/ai-register.py [register.xlsx] [--date YYYY-MM-DD] [--out DIR]
  python scripts/ai-register.py --selftest

The workbook is the list of the register saved from 1C («Ещё» → «Вывести список»): columns «Период», «Шифр»,
«Описание», maybe some title rows above the header. Default input .local/ai/register.xlsx, default output
directory .local/ai (git-ignored: the texts of the formulations never go into git).

Writes:
  register.json   all records [{period: "YYYY-MM-DD", code, text}], sorted by code and period; the input of
                  б24тТест_ДанныеИИ.ЗагрузитьФормулировки.
  places.txt      the table for decision 14.2: every fragment that may be a place to fill (a hint in brackets or in
                  quotes, question marks, dots, the ellipsis), how many current formulations have it, one example,
                  and the proposed kind: «обязательное», «необязательное», «не место».
Prints a summary: counts, period range, empty descriptions (formulations taken out of use?), the slice at --date
(default: today), and the fragments that look like personal data (BIN/IIN, e-mail, phone, surname with initials),
checked before the texts are sent to OpenAI.
"""
import argparse
import datetime
import json
import os
import re
import sys
import tempfile
from collections import OrderedDict

HEADER_WORDS = {"period": ("период",), "code": ("шифр",), "text": ("описание",)}

# Hints that are a place to fill when they stand in brackets. The kind is a proposal for the user to approve.
OPTIONAL_HINTS = ("название иб", "если надо")


def parse_period(value):
    if value is None or value == "":
        return None
    if isinstance(value, datetime.datetime):
        return value.date()
    if isinstance(value, datetime.date):
        return value
    text = str(value).strip()
    for fmt in ("%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M", "%d.%m.%Y", "%Y-%m-%d", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.datetime.strptime(text, fmt).date()
        except ValueError:
            pass
    raise ValueError("не удалось разобрать период: %r" % (value,))


def read_rows(path):
    """The records of the workbook: [{period: date, code: str, text: str}] in file order."""
    import openpyxl

    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheet = workbook.worksheets[0]
    columns = None
    rows = []
    for cells in sheet.iter_rows(values_only=True):
        if columns is None:
            names = [str(c).strip().lower() if c is not None else "" for c in cells]
            found = {}
            for key, words in HEADER_WORDS.items():
                for index, name in enumerate(names):
                    if name in words:
                        found[key] = index
            if "code" in found and "text" in found:
                columns = found
            continue
        code = cells[columns["code"]] if columns["code"] < len(cells) else None
        text = cells[columns["text"]] if columns["text"] < len(cells) else None
        if code is None and text is None:
            continue
        period = cells[columns["period"]] if "period" in columns and columns["period"] < len(cells) else None
        rows.append({
            "period": parse_period(period),
            "code": "" if code is None else str(code).strip(),
            "text": "" if text is None else str(text),
        })
    workbook.close()  # a read-only workbook keeps the file open; Windows can't delete or move it then
    if columns is None:
        raise SystemExit("В файле нет заголовка с колонками «Шифр» и «Описание».")
    return rows


def current_slice(rows, on_date):
    """The latest record of every code up to and including on_date (the later one in the file wins on a tie)."""
    best = OrderedDict()
    for index, row in enumerate(rows):
        if row["period"] is not None and row["period"] > on_date:
            continue
        key = row["code"]
        rank = (row["period"] or datetime.date.min, index)
        if key not in best or rank >= best[key][0]:
            best[key] = (rank, row)
    return [row for _, row in best.values()]


FRAGMENT_PATTERNS = (
    ("скобки", re.compile(r"\(([^()]{0,80})\)")),
    ("кавычки", re.compile(r'"([^"]{1,40})"')),
    ("вопросы", re.compile(r"\?{2,}")),
    ("точки", re.compile(r"\.{3,}")),
    ("многоточие", re.compile("…")),
)


def fragments(text):
    """The candidate places of one text: [(kind of pattern, fragment as written)]."""
    result = []
    for name, pattern in FRAGMENT_PATTERNS:
        for match in pattern.finditer(text):
            result.append((name, match.group(0)))
    return result


def proposed_kind(name, fragment):
    low = fragment.lower()
    if name == "скобки":
        inner = low[1:-1].strip()
        if any(inner.startswith(hint) for hint in OPTIONAL_HINTS):
            return "необязательное"
        if re.search(r"[?]|\.{2,}|…", inner) or re.match(r"(чей|кто|указать|рег|номер|название|сколько)", inner):
            return "обязательное"
        return "не место"
    if name == "кавычки":
        inner = low[1:-1].strip()
        return "обязательное" if re.fullmatch(r"(чей|кто|чья|чьи|какой|какая)", inner) else "не место"
    return "обязательное"


def example(text, fragment, width=30):
    index = text.find(fragment)
    start = max(0, index - width)
    end = min(len(text), index + len(fragment) + width)
    return ("…" if start else "") + text[start:end].replace("\n", " ") + ("…" if end < len(text) else "")


def places_table(current):
    """Rows of the table for decision 14.2: fragment → formulations that have it, example, proposed kind."""
    table = OrderedDict()
    for row in current:
        for name, fragment in fragments(row["text"]):
            entry = table.setdefault((name, fragment), {"codes": set(), "example": example(row["text"], fragment)})
            entry["codes"].add(row["code"])
    lines = ["Вид\tФрагмент\tВ скольких формулировках\tПредлагаю\tПример"]
    ordered = sorted(table.items(), key=lambda item: (-len(item[1]["codes"]), item[0][1]))
    for (name, fragment), entry in ordered:
        lines.append("\t".join((name, fragment, str(len(entry["codes"])), proposed_kind(name, fragment), entry["example"])))
    return "\n".join(lines) + "\n"


PERSONAL = (
    ("БИН/ИИН (12 цифр)", re.compile(r"(?<!\d)\d{12}(?!\d)")),
    ("e-mail", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    ("телефон", re.compile(r"(?<!\d)(?:\+7|8)[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}(?!\d)")),
    ("фамилия с инициалами", re.compile(r"\b[А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ]\.\s*[А-ЯЁ]\.")),
)


def personal_data(rows):
    found = []
    for row in rows:
        for name, pattern in PERSONAL:
            for match in pattern.finditer(row["text"]):
                found.append((name, row["code"], example(row["text"], match.group(0), 15)))
    return found


def summary(rows, current, on_date):
    codes = {row["code"] for row in rows}
    periods = [row["period"] for row in rows if row["period"]]
    empty = [row for row in rows if not row["text"].strip()]
    in_use = [row for row in current if row["text"].strip()]
    ties = {}
    for row in rows:
        ties.setdefault((row["code"], row["period"]), 0)
        ties[(row["code"], row["period"])] += 1
    lines = [
        "Записей: %d, шифров: %d" % (len(rows), len(codes)),
        "Период: %s … %s" % (min(periods) if periods else "—", max(periods) if periods else "—"),
        "Пустых описаний: %d (шифров с последней записью без описания на %s: %d)"
        % (len(empty), on_date, len([r for r in current if not r["text"].strip()])),
        "Действующих на %s: %d формулировок, %d символов" % (on_date, len(in_use), sum(len(r["text"]) for r in in_use)),
        "Две записи одного шифра на один день: %d" % len([k for k, n in ties.items() if n > 1]),
    ]
    return "\n".join(lines)


def write_outputs(rows, current, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    ordered = sorted(rows, key=lambda r: (r["code"], r["period"] or datetime.date.min))
    with open(os.path.join(out_dir, "register.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump([{"period": r["period"].isoformat() if r["period"] else None, "code": r["code"], "text": r["text"]}
                   for r in ordered], handle, ensure_ascii=False, indent=1)
    in_use = [row for row in current if row["text"].strip()]
    with open(os.path.join(out_dir, "places.txt"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(places_table(in_use))


def run(path, on_date, out_dir):
    rows = read_rows(path)
    current = current_slice(rows, on_date)
    write_outputs(rows, current, out_dir)
    print(summary(rows, current, on_date))
    leaks = personal_data([r for r in current if r["text"].strip()])
    print("Похоже на личные данные: %d" % len(leaks))
    for name, code, snippet in leaks:
        print("  %s, шифр %s: %s" % (name, code, snippet))
    print("Записано: %s" % os.path.join(out_dir, "register.json"))
    print("Записано: %s" % os.path.join(out_dir, "places.txt"))


def selftest():
    import openpyxl

    def check(condition, message):
        if not condition:
            raise SystemExit("FAIL: " + message)

    check(parse_period("01.02.2025 0:00:00") == datetime.date(2025, 2, 1), "период с временем")
    check(parse_period(datetime.datetime(2025, 2, 1, 5, 0)) == datetime.date(2025, 2, 1), "период datetime")
    sample = [
        {"period": datetime.date(2025, 1, 1), "code": "A", "text": "Старая А (чей ПК)."},
        {"period": datetime.date(2025, 6, 1), "code": "A", "text": "Новая А (чей ПК), версия 3.0....."},
        {"period": datetime.date(2025, 1, 1), "code": "B", "text": "Бэ (название ИБ) в ИБ ???"},
        {"period": datetime.date(2025, 1, 1), "code": "C", "text": "Це (30 МРП) ПК \"чей\" Иванов И.И."},
        {"period": datetime.date(2025, 1, 1), "code": "D", "text": "Снята"},
        {"period": datetime.date(2025, 7, 1), "code": "D", "text": ""},
        {"period": datetime.date(2026, 1, 1), "code": "E", "text": "Будущая (если надо)"},
    ]
    current = current_slice(sample, datetime.date(2025, 12, 31))
    by_code = {r["code"]: r["text"] for r in current}
    check(by_code["A"].startswith("Новая"), "срез берёт последнюю запись")
    check(by_code["D"] == "", "снятая формулировка видна пустым описанием")
    check("E" not in by_code, "запись из будущего в срез не входит")
    kinds = {frag: proposed_kind(name, frag) for row in current for name, frag in fragments(row["text"])}
    check(kinds["(чей ПК)"] == "обязательное", "(чей ПК)")
    check(kinds["(название ИБ)"] == "необязательное", "(название ИБ)")
    check(kinds["(30 МРП)"] == "не место", "(30 МРП)")
    check(kinds['"чей"'] == "обязательное", "подсказка в кавычках")
    check(kinds["???"] == "обязательное" and kinds["....."] == "обязательное", "вопросы и точки")
    check(any(name == "фамилия с инициалами" for name, _, _ in personal_data(current)), "фамилия с инициалами")

    with tempfile.TemporaryDirectory() as directory:
        workbook = openpyxl.Workbook()
        sheet = workbook.active
        sheet.append(["ГЕМ Шаблоны для заполнения табелей"])
        sheet.append([])
        sheet.append(["Период", "Шифр", "Описание"])
        for row in sample:
            sheet.append([datetime.datetime.combine(row["period"], datetime.time()), row["code"], row["text"]])
        path = os.path.join(directory, "register.xlsx")
        workbook.save(path)
        rows = read_rows(path)
        check(len(rows) == len(sample), "строк из xlsx: %d" % len(rows))
        write_outputs(rows, current_slice(rows, datetime.date(2025, 12, 31)), directory)
        data = json.load(open(os.path.join(directory, "register.json"), encoding="utf-8"))
        check(len(data) == len(sample) and data[0]["code"] == "A", "register.json")
        places = open(os.path.join(directory, "places.txt"), encoding="utf-8").read()
        check("(чей ПК)" in places and "(30 МРП)" in places, "places.txt")
    print("ai-register.py: все проверки пройдены")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("xlsx", nargs="?", default=".local/ai/register.xlsx")
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--out", default=".local/ai")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if not os.path.isfile(args.xlsx):
        raise SystemExit("Нет файла %s" % args.xlsx)
    run(args.xlsx, datetime.date.fromisoformat(args.date), args.out)


if __name__ == "__main__":
    main()
