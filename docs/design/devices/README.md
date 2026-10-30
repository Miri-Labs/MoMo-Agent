# README device illustration

The English and Chinese README illustrations use three freely downloadable 3D models, rendered together with one orthographic camera. They illustrate Watch capture, iPhone transcription, and the Mac agent. The pictured hardware models are examples, not minimum hardware requirements. The watch displays MoMo's recording screen and the phone displays MoMo's chat home, using the existing localized screenshots in `docs/assets/watch-and-iphone-en.png` and `docs/assets/watch-and-iphone-zh.png`. The screenshots are mapped onto the actual 3D screen planes; the Mac mini has no display.

## Attribution and license

All three source models were downloaded for free from Sketchfab on 2026-10-30. **The Series 11 watch is licensed for noncommercial use only.** Its restriction applies to the watch imagery in these illustrations, not to the project's application code. Obtain separate permission or replace the watch asset before using these illustrations commercially.

| Model | Creator | Source | License |
| --- | --- | --- | --- |
| Apple Watch Series 11 Jet Black - 2048px² | [Mark Peters](https://sketchfab.com/mark-peters) | [Free 3D model](https://sketchfab.com/3d-models/apple-watch-series-11-jet-black-2048px2-f78fcc4989cb45a6865b397af7fb2c98) | [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) |
| iphone 17 pro max | [izatrcsldssb](https://sketchfab.com/izatrcsldssb) | [Free 3D model](https://sketchfab.com/3d-models/iphone-17-pro-max-d24511d4d7534a4b89efdcf8fb6fae88) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Mac Mini M4 | [B41dur](https://sketchfab.com/B41dur) | [Free 3D model](https://sketchfab.com/3d-models/mac-mini-m4-0f077eb1cbb04a97a46ed5d7bdf78a51) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Modifications: dimensions calibrated to the listed hardware; three-quarter orientation; shared lighting and composition; watch sport band curved from the supplied flat pose while keeping the case rigid; adjusted Mac body and port materials; simplified phone glass; MoMo screenshots cropped from the existing README artwork and applied as watch/phone screen textures; localized labels. These are independent community models, not Apple CAD drawings. Small modelling details, including ports, can differ from the actual products.

The adapted device imagery in `docs/assets/devices-3d-en.png` and `docs/assets/devices-3d-zh.png` retains the above attribution and respective CC BY-NC / CC BY 4.0 notices. Apple device names and marks belong to Apple; the MoMo avatar remains the project's existing brand asset. No creator or Apple endorsement is implied.

## Physical scale

Scene units are millimetres. All devices share the same camera and projection; no device is resized separately after rendering.

| Device | Calibration | Official dimensions |
| --- | --- | --- |
| Apple Watch Series 11 (46 mm) | Case: 46 × 39 × 9.7 mm; strap posed separately, Digital Crown excluded from case-width calibration | [Apple Series 11 specs](https://support.apple.com/en-mide/125093) |
| iPhone 17 Pro Max | Body: 163.4 × 78 × 8.75 mm; camera bump excluded from body-depth calibration | [Apple specifications](https://support.apple.com/en-us/125091) |
| Mac mini M4 | Body: 127 × 127 × 50 mm | [Apple Mac mini (2024) specs](https://support.apple.com/en-us/121555) |

The Series 11 source is a single mesh. Its case bounds in original mesh coordinates are X −0.940325…0.940192, Y −1.044758…1.044706, and depth Z 0.050781…0.410000 including the back sensor. These anchors set the physical scale; the full strap bounding box is not used. Only vertices beyond the case at |Y| > 1.05 are bent, with transformed normals. The flat screen surface is used for the MoMo recording screenshot. The iPhone source's original bounds are adjusted to the named device's dimensions. Runtime assertions check the watch's source anchors and width/height scale, iPhone body width/height, and Mac body width/height before rendering. Depth, curved surfaces, strap fit and manufacturing tolerances remain illustrative.

## Reproduce

On macOS with Xcode installed, download each source's **USDZ** format through its normal download flow, then save them together as `watch-series-11.usdz`, `iphone.usdz`, and `mac-mini.usdz`. Full model files are not added to this repository.

```sh
swift docs/design/devices/render.swift /absolute/path/to/models
```

This writes the two localized 2000 × 1100 PNGs under `docs/assets/` using native SceneKit and AppKit. No paid rendering service or additional package is required.

Downloaded USDZ SHA-256 checksums:

```text
watch-series-11.usdz  a514389fd068b15843d7eb6d59b8200c95db0adcd3bd9d6a028aabfbd5e69edd
iphone.usdz    85e687a47363e042fd58ef8c769e5d68a05204b3e9894726ddf3371a46ba4dcf
mac-mini.usdz  d9c7fac8feddc233ccc93cd550a0d478f8f2d5742ccd5357cdf9a16d40c72037
```
