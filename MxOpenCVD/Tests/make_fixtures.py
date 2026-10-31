#!/usr/bin/env python3
"""Regenerates Tests/fixtures. Needs pillow and onnx. The outputs are committed, so tests don't need Python."""
import os
import sys

import onnx
from onnx import TensorProto, helper, numpy_helper
import numpy as np
from PIL import Image, ImageDraw, ImageFont

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "fixtures")
os.makedirs(out, exist_ok=True)

# A printed part label, in the sort of type a close-up camera sees.
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 44)
small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 30)
image = Image.new("RGB", (900, 320), (246, 244, 238))
draw = ImageDraw.Draw(image)
draw.text((50, 40), "LOT A7-20391", font=font, fill=(20, 20, 20))
draw.text((50, 120), "EXP 2027-03-15", font=font, fill=(20, 20, 20))
draw.text((50, 210), "Made in USA  REF 88-1402", font=small, fill=(40, 40, 40))
image.save(os.path.join(out, "label.png"))

# YOLO models that always give the same boxes in a 64 × 64 input: a strong one, a weaker near-duplicate that
# suppression must remove, one of another class, one below the confidence limit, and empty rows to make up the
# many-rows-few-columns shape of a real export. The second file has the last two dimensions swapped.
boxes = np.zeros((1, 12, 6), dtype=np.float32)
boxes[0, :4] = [[32, 32, 20, 20, 0.9, 0.1],
                [33, 32, 20, 20, 0.8, 0.1],
                [10, 50, 8, 8, 0.1, 0.7],
                [50, 10, 4, 4, 0.1, 0.1]]


def save_constant_model(values, name):
    constant = helper.make_node("Constant", [], ["boxes"], value=numpy_helper.from_array(values, "value"))
    graph = helper.make_graph(
        [constant], "tiny_yolo",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 3, 64, 64])],
        [helper.make_tensor_value_info("boxes", TensorProto.FLOAT, list(values.shape))])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)], ir_version=8)
    onnx.checker.check_model(model)
    onnx.save(model, os.path.join(out, name))


save_constant_model(boxes, "tiny_yolo.onnx")
save_constant_model(np.transpose(boxes, (0, 2, 1)), "tiny_yolo_channels_first.onnx")


def data_matrix_14x14(text):
    """An ECC200 Data Matrix (ISO 16022) as rows of 0 and 1. Core Image can't make these, so the test needs its own."""
    # ASCII encoding, with each pair of digits packed into one codeword.
    words, i = [], 0
    while i < len(text):
        if text[i:i + 2].isdigit() and len(text[i:i + 2]) == 2:
            words.append(130 + int(text[i:i + 2]))
            i += 2
        else:
            words.append(ord(text[i]) + 1)
            i += 1
    assert len(words) <= 8, "too long for a 14 x 14 symbol"
    if len(words) < 8:
        words.append(129)
    while len(words) < 8:
        position = len(words) + 1
        pad = 129 + (149 * position) % 253 + 1
        words.append(pad if pad <= 254 else pad - 254)

    # Reed-Solomon over GF(256) with polynomial 301, 10 error-correction codewords.
    exp, log, x = [0] * 512, [0] * 256, 1
    for n in range(255):
        exp[n], log[x] = x, n
        x = (x << 1) ^ (301 if x & 0x80 else 0)
    for n in range(255, 512):
        exp[n] = exp[n - 255]
    generator = [1]
    for root in range(1, 11):
        next_poly = [0] * (len(generator) + 1)
        for n, c in enumerate(generator):
            next_poly[n] ^= c
            next_poly[n + 1] ^= exp[log[c] + root] if c else 0
        generator = next_poly
    remainder = [0] * 10
    for word in words:
        factor = word ^ remainder[0]
        remainder = remainder[1:] + [0]
        if factor:
            for n in range(10):
                remainder[n] ^= exp[log[factor] + log[generator[n + 1]]] if generator[n + 1] else 0
    codewords = words + remainder

    # Module placement, ISO 16022 annex F.
    size = 12
    grid = [[None] * size for _ in range(size)]

    def module(row, col, word, bit):
        if row < 0:
            row += size
            col += 4 - ((size + 4) % 8)
        if col < 0:
            col += size
            row += 4 - ((size + 4) % 8)
        grid[row][col] = (codewords[word - 1] >> (8 - bit)) & 1

    def place(word, cells):
        for bit, (row, col) in enumerate(cells, 1):
            module(row, col, word, bit)

    def utah(row, col, word):
        place(word, [(row - 2, col - 2), (row - 2, col - 1), (row - 1, col - 2), (row - 1, col - 1),
                     (row - 1, col), (row, col - 2), (row, col - 1), (row, col)])

    n = size
    word, row, col = 1, 4, 0
    while True:
        if row == n and col == 0:
            place(word, [(n - 1, 0), (n - 1, 1), (n - 1, 2), (0, n - 2), (0, n - 1), (1, n - 1), (2, n - 1), (3, n - 1)])
            word += 1
        if row == n - 2 and col == 0 and n % 4:
            place(word, [(n - 3, 0), (n - 2, 0), (n - 1, 0), (0, n - 4), (0, n - 3), (0, n - 2), (0, n - 1), (1, n - 1)])
            word += 1
        if row == n - 2 and col == 0 and n % 8 == 4:
            place(word, [(n - 3, 0), (n - 2, 0), (n - 1, 0), (0, n - 2), (0, n - 1), (1, n - 1), (2, n - 1), (3, n - 1)])
            word += 1
        if row == n + 4 and col == 2 and n % 8 == 0:
            place(word, [(n - 1, 0), (n - 1, n - 1), (0, n - 3), (0, n - 2), (0, n - 1), (1, n - 3), (1, n - 2), (1, n - 1)])
            word += 1
        while True:
            if row < n and col >= 0 and grid[row][col] is None:
                utah(row, col, word)
                word += 1
            row -= 2
            col += 2
            if not (row >= 0 and col < n):
                break
        row += 1
        col += 3
        while True:
            if row >= 0 and col < n and grid[row][col] is None:
                utah(row, col, word)
                word += 1
            row += 2
            col -= 2
            if not (row < n and col >= 0):
                break
        row += 3
        col += 1
        if not (row < n or col < n):
            break
    if grid[n - 1][n - 1] is None:
        grid[n - 1][n - 1] = grid[n - 2][n - 2] = 1

    # The finder: a solid left and bottom edge, and a dotted top and right edge.
    rows = []
    for y in range(14):
        cells = []
        for x in range(14):
            if x == 0 or y == 13:
                cells.append(1)
            elif y == 0:
                cells.append(0 if x % 2 else 1)
            elif x == 13:
                cells.append(1 if y % 2 else 0)
            else:
                cells.append(grid[y - 1][x - 1])
        rows.append("".join(map(str, cells)))
    return rows


# Pasted into SelfTest.swift, since the app's self-test can't read files from the repository.
with open(os.path.join(out, "datamatrix.txt"), "w") as f:
    f.write("\n".join(data_matrix_14x14("MXV-12345")) + "\n")
print("Wrote", os.listdir(out), file=sys.stderr)
