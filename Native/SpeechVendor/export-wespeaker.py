# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["onnx==1.19.1", "onnxconverter-common==1.16.0", "numpy"]
# ///
"""Reproduce the shipped fixed 3 s FP16 graph from the pinned upstream WeSpeaker.

Uses the prepared ORT 1.28.2 macOS framework; never downloads or modifies user audio.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np
import onnx
from onnx import helper, numpy_helper
from onnxconverter_common import float16

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export(source, output, framework):
    manifest = json.loads((ROOT / "speaker-manifest.json").read_text())
    if sha(source) != manifest["embeddingSource"]["sha256"]:
        raise ValueError("Unexpected upstream WeSpeaker SHA256")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wespeaker-export-", dir=output.parent) as temporary:
        scratch = Path(temporary)
        model = onnx.load(source)
        shape = model.graph.input[0].type.tensor_type.shape.dim
        assert len(shape) == 3
        for dimension, size in zip(shape, [1, 300, 80]):
            dimension.ClearField("dim_param")
            dimension.dim_value = size
        del model.graph.value_info[:]
        model = onnx.shape_inference.infer_shapes(model)
        onnx.checker.check_model(model)
        fixed, folded = scratch / "fixed.onnx", scratch / "folded.onnx"
        onnx.save(model, fixed)
        binary = scratch / "fold-constants"
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", str(ROOT / "fold-speaker-constants.cpp"),
                        "-F", str(framework.parent), "-framework", "onnxruntime",
                        "-Wl,-rpath," + str(framework.parent), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(fixed), str(folded)], check=True)
        model = onnx.shape_inference.infer_shapes(onnx.load(folded), data_prop=True)
        shapes = {v.name: [d.dim_value for d in v.type.tensor_type.shape.dim] for v in model.graph.value_info}
        replacements = 0
        for node in model.graph.node:
            if node.op_type != "Flatten":
                continue
            dimensions = shapes[node.input[0]]
            assert all(x > 0 for x in dimensions)
            assert next((a.i for a in node.attribute if a.name == "axis"), 1) == 1
            name = node.name + "/static_shape"
            model.graph.initializer.append(numpy_helper.from_array(np.array([dimensions[0], int(np.prod(dimensions[1:]))], dtype=np.int64), name))
            node.op_type = "Reshape"
            node.input.append(name)
            del node.attribute[:]
            replacements += 1
        assert replacements == 2
        half = float16.convert_float_to_float16(model, keep_io_types=True, disable_shape_infer=True)
        types = {v.name: v.type.tensor_type.elem_type for v in [*half.graph.input, *half.graph.output, *half.graph.value_info]}
        for node in half.graph.node:
            if node.op_type == "Cast" and types.get(node.output[0]) == onnx.TensorProto.FLOAT16:
                for attribute in node.attribute:
                    if attribute.name == "to" and attribute.i == onnx.TensorProto.FLOAT:
                        attribute.i = onnx.TensorProto.FLOAT16
        onnx.checker.check_model(half, full_check=True)
        candidate = scratch / "wespeaker.onnx"
        onnx.save(half, candidate)
        expected = manifest["files"]["wespeaker-3s-coreml-fp16.onnx"]
        if sha(candidate) != expected:
            raise ValueError(f"Export differs from shipped model: {sha(candidate)} != {expected}; verify ORT 1.28.2")
        candidate.replace(output)
    print(f"Verified fixed-shape FP16 WeSpeaker: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ort-framework", type=Path, required=True)
    args = parser.parse_args()
    export(args.source.resolve(), args.output.resolve(), args.ort_framework.resolve())
