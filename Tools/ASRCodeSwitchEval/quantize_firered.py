"""Build 4-bit weight-only variants of the sherpa-onnx FireRedASR2-AED export with ONNX Runtime MatMulNBits.

Inputs are the official sherpa-onnx exports of the same model (identical lineage, all hashes in the doc):
  --fp32  csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-2026-02-26 (encoder.onnx + encoder.weights, decoder.onnx)
  --int8  sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26 (encoder.int8.onnx, decoder.int8.onnx, tokens.txt)

Variants:
  int4      encoder and decoder from fp32. The conformer's 1x1 (pointwise) Conv layers hold 635 MB of the
            3.1 GB encoder and MatMulNBits only covers MatMul/Gather, so each Conv with kernel 1, stride 1,
            no padding and group 1 is first rewritten as Transpose -> MatMul -> Add -> Transpose (exact in
            fp32). Then every MatMul with a constant weight, and the decoder's token-embedding Gather, is
            quantized to 4 bits (blockwise, asymmetric). Depthwise/subsampling Convs, LayerNorm and the
            positional-encoding tables stay fp32 (the released int8 model also keeps the tables fp32).
  int8enc   encoder.int8.onnx exactly as released; decoder 4-bit from fp32 as above.

    uv run --python 3.12 --with onnxruntime==1.28.0 --with onnx==1.19.1 --with onnx-ir==1.1.0 \
        --with numpy==2.3.4 python -I Tools/ASRCodeSwitchEval/quantize_firered.py \
        --fp32 DIR --int8 DIR --variant int4 --block-size 32 --accuracy-level 4 --output NEW_DIR

The output directory holds encoder.onnx, decoder.onnx, tokens.txt and quantize.json (settings + SHA256).
"""

import argparse
import gc
import hashlib
import json
import shutil
import time
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def attribute(node, name, default):
    for attr in node.attribute:
        if attr.name == name:
            return helper.get_attribute_value(attr)
    return default


def pointwise_conv_to_matmul(model):
    """Rewrite 1-D Conv nodes with kernel 1 (no stride/pad/dilation/groups) as MatMul on the channel axis."""
    graph = model.graph
    weights = {init.name: init for init in graph.initializer}
    new_nodes, rewritten = [], 0
    for node in graph.node:
        weight = weights.get(node.input[1]) if node.op_type == "Conv" and len(node.input) > 1 else None
        if (weight is None or len(weight.dims) != 3 or weight.dims[2] != 1 or attribute(node, "group", 1) != 1
                or any(s != 1 for s in attribute(node, "strides", [1]))
                or any(p != 0 for p in attribute(node, "pads", [0, 0]))
                or any(d != 1 for d in attribute(node, "dilations", [1]))):
            new_nodes.append(node)
            continue
        array = numpy_helper.to_array(weight)  # (C_out, C_in, 1)
        matrix_name = weight.name + ".as_matmul"
        graph.initializer.append(numpy_helper.from_array(np.ascontiguousarray(array[:, :, 0].T), matrix_name))
        prefix = node.name or node.output[0]
        x_t, product = prefix + "/x_t", prefix + "/matmul"
        new_nodes.append(helper.make_node("Transpose", [node.input[0]], [x_t], perm=[0, 2, 1], name=prefix + "/Transpose_in"))
        new_nodes.append(helper.make_node("MatMul", [x_t, matrix_name], [product], name=prefix + "/MatMul"))
        if len(node.input) > 2 and node.input[2]:
            biased = prefix + "/bias"
            new_nodes.append(helper.make_node("Add", [product, node.input[2]], [biased], name=prefix + "/Add"))
            product = biased
        new_nodes.append(helper.make_node("Transpose", [product], [node.output[0]], perm=[0, 2, 1], name=prefix + "/Transpose_out"))
        rewritten += 1
    del graph.node[:]
    graph.node.extend(new_nodes)
    used = {name for node in graph.node for name in node.input}
    keep = [init for init in graph.initializer if init.name in used]
    del graph.initializer[:]
    graph.initializer.extend(keep)
    return rewritten


def quantize(model, block_size, accuracy_level, gather):
    from onnxruntime.quantization import matmul_nbits_quantizer as mnb

    op_types = ("MatMul", "Gather") if gather else ("MatMul",)
    config = mnb.DefaultWeightOnlyQuantConfig(block_size=block_size, is_symmetric=False,
                                              accuracy_level=accuracy_level, op_types_to_quantize=op_types,
                                              quant_axes=(("MatMul", 0), ("Gather", 1)), bits=4)
    quantizer = mnb.MatMulNBitsQuantizer(model, block_size=block_size, is_symmetric=False,
                                         accuracy_level=accuracy_level, op_types_to_quantize=op_types,
                                         quant_axes=(("MatMul", 0), ("Gather", 1)), algo_config=config)
    quantizer.process()
    return quantizer.model.model


def op_counts(model):
    counts = {}
    for node in model.graph.node:
        counts[node.op_type] = counts.get(node.op_type, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: -kv[1]))


def build_part(source, target, block_size, accuracy_level, rewrite_conv, gather):
    started = time.perf_counter()
    model = onnx.load(str(source))  # Loads external data (encoder.weights) too.
    opset = {o.domain: o.version for o in model.opset_import}.get("", None)
    rewritten = pointwise_conv_to_matmul(model) if rewrite_conv else 0
    model = quantize(model, block_size, accuracy_level, gather)
    # The quantizer raises the default-domain opset (17 -> 21). The graph was exported for opset 17 and the
    # quantizer only adds com.microsoft ops, so restore 17: under opset >= 18 the exported Split nodes (no
    # num_outputs attribute) are invalid and ORT refuses to load the encoder.
    raised = {o.domain: o.version for o in model.opset_import}.get("", None)
    for entry in model.opset_import:
        if entry.domain in ("", "ai.onnx") and opset is not None:
            entry.version = opset
    onnx.save(model, str(target))
    info = dict(source=source.name, convRewrittenAsMatMul=rewritten, ops=op_counts(model),
                opset=dict(source=opset, afterQuantizer=raised, saved=opset),
                seconds=round(time.perf_counter() - started, 1))
    del model
    gc.collect()
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fp32", type=Path, required=True)
    parser.add_argument("--int8", type=Path, required=True)
    parser.add_argument("--variant", choices=["int4", "int8enc"], required=True)
    parser.add_argument("--block-size", type=int, default=32)
    parser.add_argument("--accuracy-level", type=int, default=4)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"Output directory must not exist: {args.output}")
    staging = args.output.with_name(args.output.name + ".building")
    staging.mkdir(parents=True)
    import onnxruntime

    record = dict(variant=args.variant, blockSize=args.block_size, accuracyLevel=args.accuracy_level,
                  bits=4, symmetric=False, onnxruntime=onnxruntime.__version__, onnx=onnx.__version__,
                  inputs={str(p.relative_to(p.parent.parent)): sha256_file(p) for p in [
                      args.fp32 / "encoder.onnx", args.fp32 / "encoder.weights", args.fp32 / "decoder.onnx",
                      args.int8 / "encoder.int8.onnx", args.int8 / "tokens.txt"]})
    if args.variant == "int4":
        record["encoder"] = build_part(args.fp32 / "encoder.onnx", staging / "encoder.onnx", args.block_size,
                                       args.accuracy_level, rewrite_conv=True, gather=True)
    else:
        shutil.copyfile(args.int8 / "encoder.int8.onnx", staging / "encoder.onnx")
        record["encoder"] = dict(source="encoder.int8.onnx (released, unchanged)")
    record["decoder"] = build_part(args.fp32 / "decoder.onnx", staging / "decoder.onnx", args.block_size,
                                   args.accuracy_level, rewrite_conv=False, gather=True)
    shutil.copyfile(args.int8 / "tokens.txt", staging / "tokens.txt")
    record["outputs"] = {p.name: dict(bytes=p.stat().st_size, sha256=sha256_file(p))
                         for p in sorted(staging.iterdir()) if p.is_file()}
    (staging / "quantize.json").write_text(json.dumps(record, indent=2) + "\n")
    staging.rename(args.output)
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
