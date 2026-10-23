import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Circle, FancyArrowPatch

plt.rcParams["font.family"] = "Arial"
OUT = sys.argv[1]

BLUE = "#2F6FB0"
GRAY = "#7A8794"
GREEN = "#2E7D4F"
GREEN_BG = "#E8F3EA"
ORANGE = "#B07400"
ORANGE_BG = "#FFF4DD"
RED = "#B3261E"
INK = "#1F2933"
LANE_BG = "#F4F6F9"
LANE_LINE = "#DCE1E7"
BLUE_BG = "#EAF2FB"


def box(ax, x, y, w, h, text, edge=BLUE, fill="white", num=None, numcol=None, size=22, lw=3):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.18",
                                linewidth=lw, edgecolor=edge, facecolor=fill, zorder=3))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=size, color=INK,
            zorder=4, linespacing=1.35)
    if num is not None:
        ax.add_patch(Circle((x + 0.05, y + h - 0.02), 0.33, facecolor=numcol or edge, edgecolor="white",
                            linewidth=3, zorder=5))
        ax.text(x + 0.05, y + h - 0.02, str(num), ha="center", va="center", fontsize=21, color="white",
                zorder=6)


def arrow(ax, pts, label=None, lpos=None, color=GRAY, dashed=False):
    for i in range(len(pts) - 1):
        last = i == len(pts) - 2
        ax.add_patch(FancyArrowPatch(pts[i], pts[i + 1], arrowstyle="-|>" if last else "-",
                                     mutation_scale=26, color=color, linewidth=3, zorder=2,
                                     linestyle=(0, (4, 3)) if dashed else "solid",
                                     shrinkA=0, shrinkB=0))
    if label:
        x, y = lpos
        ax.text(x, y, label, ha="center", va="center", fontsize=18, color="#3E4C59", zorder=7,
                bbox=dict(facecolor="white", edgecolor="none", pad=2.5))


def lanes(ax, names, top, lane_h, width):
    for i, name in enumerate(names):
        y = top - (i + 1) * lane_h
        ax.add_patch(FancyBboxPatch((0.05, y + 0.06), width - 0.1, lane_h - 0.12,
                                    boxstyle="round,pad=0,rounding_size=0.15", linewidth=2,
                                    edgecolor=LANE_LINE, facecolor=LANE_BG, zorder=0))
        ax.text(1.05, y + lane_h / 2, name, ha="center", va="center", fontsize=19, color="#52606D",
                linespacing=1.3, zorder=1)


def flow():
    W, H = 21.3, 12.2
    fig = plt.figure(figsize=(W, H), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(0, H)
    ax.axis("off")
    lane_h = 4.0
    lanes(ax, ["Сотрудник\nи форма\nтабеля", "Сервер 1С,\nрасширение", "Битрикс24,\nвходящий\nвебхук"],
          H - 0.05, lane_h, W)
    bw, bh = 3.35, 2.6
    cols = [2.2 + i * 3.8 for i in range(5)]
    rows = [H - 0.05 - lane_h * k - lane_h / 2 - bh / 2 for k in range(3)]

    def b(c, r, text, **kw):
        box(ax, cols[c], rows[r], bw, bh, text, **kw)
        return cols[c], rows[r]

    b(0, 0, "Нажимает\n«Заполнить\nиз задачи Б24»", num=1)
    b(0, 1, "Проверки в 1С:\nфизлицо,\nсвой табель,\ne-mail", num=2)
    b(1, 2, "user.admin,\nuser.get:\nID сотрудника\nпо e-mail", num=3, edge=GRAY)
    b(2, 2, "tasks.task.list ×2,\ncrm.company.list,\ncrm.requisite.list", num=4, edge=GRAY)
    b(2, 1, "Отбор в 1С:\nроль, 30 дней,\nпроект;\nконтрагент", num=5)
    b(3, 0, "Окно: задача\nиз списка или\nпо номеру,\nвремя и тип", num=6)
    b(3, 2, "tasks.task.get:\nзадача ещё\nподходит?", num=7, edge=GRAY)
    b(4, 0, "Строка в табеле,\nрасчёт формы;\nзаписывает\nсотрудник", num=8, edge=GREEN,
      fill=GREEN_BG, numcol=GREEN)

    cx = lambda c: cols[c] + bw / 2
    top = lambda r: rows[r] + bh
    bot = lambda r: rows[r]
    mid = lambda r: rows[r] + bh / 2
    arrow(ax, [(cx(0), bot(0)), (cx(0), top(1))])
    arrow(ax, [(cols[0] + bw, mid(1)), (cx(1), mid(1)), (cx(1), top(2))], "HTTPS, чтение",
          (cx(1), (bot(1) + top(2)) / 2))
    arrow(ax, [(cols[1] + bw, mid(2)), (cols[2], mid(2))])
    arrow(ax, [(cx(2), top(2)), (cx(2), bot(1))], "ответы JSON", (cx(2), (bot(1) + top(2)) / 2))
    arrow(ax, [(cols[2] + bw, mid(1)), (cx(3) - 0.7, mid(1)), (cx(3) - 0.7, bot(0))], "список задач",
          (cx(3) - 0.7, (bot(0) + top(1)) / 2))
    arrow(ax, [(cx(3) + 0.7, bot(0)), (cx(3) + 0.7, top(2))], "«Добавить\nв табель»",
          (cx(3) + 0.7, mid(1) + 0.2))
    arrow(ax, [(cols[3] + bw, mid(2)), (cx(4), mid(2)), (cx(4), bot(0))], "задача подходит",
          (cx(4), (bot(0) + top(1)) / 2))
    fig.savefig(OUT + "/schema-flow.png", dpi=100)


def counterparty():
    W, H = 21.3, 12.15
    fig = plt.figure(figsize=(W, H), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(0, H)
    ax.axis("off")

    def pill(x, y, w, h, text):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.75", linewidth=2.6,
                                    edgecolor=BLUE, facecolor=BLUE_BG, zorder=3))
        ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=21, color=INK, zorder=4,
                linespacing=1.3)

    def result(x, y, w, h, cond, title, body, edge, fill):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.18", linewidth=2.6,
                                    edgecolor=edge, facecolor=fill, zorder=3))
        ax.text(x + w / 2, y + h - 0.36, cond, ha="center", va="center", fontsize=17, color="#52606D", zorder=4)
        ax.text(x + w / 2, y + h - 0.98, title, ha="center", va="center", fontsize=22, color=edge, zorder=4)
        ax.text(x + w / 2, y + 0.62, body, ha="center", va="center", fontsize=18, color=INK, zorder=4,
                linespacing=1.3)

    # level 1: companies
    pill(0.2, 7.6, 3.9, 2.4, "Сколько компаний\nв «Элементах CRM»\nзадачи?")
    rw, rh = 5.9, 2.1
    rx = 4.95
    result(rx, 9.85, rw, rh, "ни одной (сделки и контакты не считаются)", "Нет контрагента",
           "«В задаче не указана компания CRM —\nвыберите контрагента вручную»", ORANGE, ORANGE_BG)
    result(rx, 7.65, rw, rh, "две и больше", "Нет контрагента",
           "«В задаче несколько компаний CRM —\nвыберите контрагента вручную»", ORANGE, ORANGE_BG)
    box(ax, rx, 4.6, rw, 2.5, "Ровно одна. Номер — первое\nиз RQ_BIN, RQ_IIN, RQ_INN\nс цифрами в первом\nактивном реквизите",
        size=19)
    trunk = 4.55
    arrow(ax, [(4.1, 8.8), (trunk, 8.8)], color=GRAY)
    for y, col in [(10.85, ORANGE), (8.65, ORANGE), (5.85, BLUE)]:
        arrow(ax, [(trunk, 8.8), (trunk, y), (rx, y)], color=col)

    # level 2: number
    result(rx, 1.7, rw, rh, "ни в одном реквизите нет цифр", "Нет контрагента",
           "«У компании «…» не заполнен БИН —\nвыберите контрагента вручную»", ORANGE, ORANGE_BG)
    arrow(ax, [(rx + 1.0, 4.6), (rx + 1.0, 3.8)], "нет номера", (rx + 1.0, 4.2), color=ORANGE)
    pill(11.3, 4.75, 3.8, 2.2, "Сколько\nконтрагентов в 1С\nс этим номером?")
    arrow(ax, [(rx + rw, 5.85), (11.3, 5.85)], color=BLUE)

    # level 3: 1C lookup
    qx, qw = 15.75, 5.4
    result(qx, 8.3, qw, 2.5, "ровно один, не помеченный на удаление", "Контрагент найден",
           "Подставляется в строку,\nпометка «найден в 1С по БИН …»", GREEN, GREEN_BG)
    result(qx, 4.8, qw, 2.1, "ни одного", "Нет контрагента",
           "«Контрагент с БИН … не найден\nв 1С — выберите контрагента…»", ORANGE, ORANGE_BG)
    result(qx, 1.6, qw, 2.1, "несколько", "Нет контрагента",
           "«В 1С несколько контрагентов\nс БИН … — выберите нужного…»", ORANGE, ORANGE_BG)
    t2 = 15.4
    arrow(ax, [(15.1, 5.85), (t2, 5.85)], color=GRAY)
    for y, col in [(9.55, GREEN), (5.85, ORANGE), (2.65, ORANGE)]:
        arrow(ax, [(t2, 5.85), (t2, y), (qx, y)], color=col)

    ax.text(0.35, 0.7, "Строка добавляется в любом случае. Если контрагента нет и тип времени «Клиент…», после добавления "
            "открывается выбор контрагента.", ha="left", va="center", fontsize=19, color=RED)
    fig.savefig(OUT + "/schema-counterparty.png", dpi=100)


flow()
counterparty()
