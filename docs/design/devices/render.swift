import AppKit
import SceneKit
import Metal
import Foundation
// Usage: swift docs/design/devices/render.swift /path/to/downloaded-usdz-models
// Requires macOS / Xcode. No third-party rendering dependencies.
precondition(CommandLine.arguments.count == 2, "Pass the directory containing watch-series-11.usdz, iphone.usdz, mac-mini.usdz")
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = repo.appendingPathComponent("docs/assets")
let scene = SCNScene()
scene.background.contents = NSColor.white
let root = scene.rootNode
func addModel(_ file:String, _ scale:SCNVector3, _ x:Double, _ yaw:Double) throws -> SCNNode {
 let src = try SCNScene(url:folder.appendingPathComponent(file))
 let content = SCNNode()
 for n in src.rootNode.childNodes { content.addChildNode(n) }
 content.scale=scale
 let scaled = SCNNode(); scaled.addChildNode(content)
 let b=scaled.boundingBox
 content.position=SCNVector3(-(b.min.x+b.max.x)/2,-b.min.y,-(b.min.z+b.max.z)/2)
 let placement=SCNNode();placement.addChildNode(scaled)
 placement.position.x=x; placement.eulerAngles.y=yaw
 root.addChildNode(placement)
 return placement
}
// Scene units are millimetres. The source meshes use different arbitrary scales.
// Series 11 case calibration excludes its unfolded strap and Digital Crown.
// Phone depth is calibrated to the body, excluding its camera bump.
func checkDimensions(_ node: SCNNode, _ width: Double, _ height: Double) {
 let b=node.boundingBox
 precondition(abs(b.max.x-b.min.x-width)<0.05 && abs(b.max.y-b.min.y-height)<0.05,"Physical scale calibration failed")
}
// The Series 11 asset is one mesh. Work in its original local coordinates,
// keep the case rigid, and bend only the two sport-band tails around a wrist.
let watchScale=SIMD3<Double>(39/1.880517,46/2.089464,9.7/(0.410000-0.050781))
let watchSource=try SCNScene(url:folder.appendingPathComponent("watch-series-11.usdz"))
var watchGeometry:SCNGeometry?
watchSource.rootNode.enumerateChildNodes { node,_ in
 if let geometry=node.geometry { precondition(watchGeometry == nil);watchGeometry=geometry }
}
let original=watchGeometry!
func vectors(_ source:SCNGeometrySource) -> [SIMD3<Double>] {
 precondition(source.bytesPerComponent == 4 && source.componentsPerVector == 3)
 return source.data.withUnsafeBytes { bytes in
  (0..<source.vectorCount).map { i in
   let offset=source.dataOffset+i*source.dataStride
   return SIMD3<Double>((0..<3).map { Double(bytes.loadUnaligned(fromByteOffset:offset+$0*4,as:Float.self)) })
  }
 }
}
let positions=vectors(original.sources(for:.vertex).first!)
let normals=vectors(original.sources(for:.normal).first!)
precondition(positions.count == normals.count)
// These source vertices anchor the case, independent of the strap's pose.
for anchor in [-0.940325,0.940192] {
 precondition(positions.contains { abs($0.x-anchor)<0.00001 })
}
for anchor in [-1.044758,1.044706] {
 precondition(positions.contains { abs($0.y-anchor)<0.00001 && $0.z>=0.11 })
}
precondition(abs(1.880517*watchScale.x-39)<0.01 && abs(2.089464*watchScale.y-46)<0.01)
var bentPositions=[SCNVector3](),bentNormals=[SCNVector3]()
for (p,n) in zip(positions,normals) {
 var point=p,normal=n
 let start=1.05,radius=1.55,depth=1.12,centerZ=0.20
 if abs(p.y)>start {
  let sign=p.y<0 ? -1.0:1.0
  let initial=asin(start/radius)
  let angle=initial+(abs(p.y)-start)/radius,offset=p.z-centerZ
  let c=cos(angle),s=sin(angle)
  point.y=sign*(radius+offset)*s
  point.z=centerZ+(depth+offset)*c-depth*cos(initial)
  let a=(radius+offset)/radius*c,b=sign*s
  let d=c,e = -sign*(depth+offset)/radius*s
  let determinant=a*d-b*e
  normal.y=(d*n.y-e*n.z)/determinant
  normal.z=(-b*n.y+a*n.z)/determinant
 }
 point *= watchScale
 normal=simd_normalize(normal/watchScale)
 bentPositions.append(SCNVector3(point.x,point.y,point.z))
 bentNormals.append(SCNVector3(normal.x,normal.y,normal.z))
}
let watchMesh=SCNGeometry(sources:[SCNGeometrySource(vertices:bentPositions),SCNGeometrySource(normals:bentNormals)]+original.sources(for:.texcoord),elements:original.elements)
watchMesh.materials=original.materials.map { source in
 let material=source.copy() as! SCNMaterial
 // The original tangent map described a flat band; retain PBR color/roughness.
 material.normal.contents=nil
 return material
}
let watchContent=SCNNode(geometry:watchMesh)
let watchSize=watchContent.boundingBox
watchContent.position=SCNVector3(-(watchSize.min.x+watchSize.max.x)/2,-watchSize.min.y,-(watchSize.min.z+watchSize.max.z)/2)
let watchScaled=SCNNode();watchScaled.addChildNode(watchContent)
let watch=SCNNode();watch.addChildNode(watchScaled);watch.position.x = -160;watch.eulerAngles.y = -0.5;root.addChildNode(watch)
let phone = try addModel("iphone.usdz",SCNVector3(78/7.31012,163.4/15.00009,8.75/0.86249),-35,-0.55)
let mac = try addModel("mac-mini.usdz",SCNVector3(127/12.70998,50/5.046542,127/12.714572),150,Double.pi+0.42)
checkDimensions(phone.childNodes[0],78,163.4)
checkDimensions(mac.childNodes[0],127,50)
mac.enumerateChildNodes { n,_ in
 for m in n.geometry?.materials ?? [] {
  if m.name == "Material_001" { m.roughness.contents=0.35;m.metalness.contents=0.8 }
  if ["Copper","Plastic_2","Alumnio_escovado","Metal_ouro"].contains(m.name ?? "") {m.diffuse.contents=NSColor(white:0.06,alpha:1);m.metalness.contents=0.3;m.roughness.contents=0.5}
 }
}
phone.enumerateChildNodes { n,_ in
 if n.name == "Object_34" { n.isHidden=true }
 for m in n.geometry?.materials ?? [] {
  if m.name == "Display" { m.diffuse.contents=NSColor(srgbRed:24/255,green:24/255,blue:24/255,alpha:1);m.lightingModel = .constant }
 }
}
// Reuse the localized MoMo screenshots already published in the README.
// Crop only the screen pixels, excluding the old device frames and captions.
func screenshot(_ language:String, _ rect:CGRect) -> NSImage {
 let source=NSImage(contentsOf:repo.appendingPathComponent("docs/assets/watch-and-iphone-\(language).png"))!
 let pixels=source.cgImage(forProposedRect:nil,context:nil,hints:nil)!
 precondition(pixels.width == 2000 && pixels.height == 1080,"Recheck screen crop coordinates when source artwork changes")
 let crop=pixels.cropping(to:rect)!
 return NSImage(cgImage:crop,size:rect.size)
}
func screen(_ width:CGFloat,_ height:CGFloat,_ radius:CGFloat,_ position:SCNVector3,_ parent:SCNNode) -> SCNMaterial {
 let geometry=SCNPlane(width:width,height:height);geometry.cornerRadius=radius
 let material=SCNMaterial();material.lightingModel = .constant
 geometry.materials=[material]
 let node=SCNNode(geometry:geometry);node.position=position;parent.addChildNode(node)
 return material
}
let watchScreen=screen(2*0.772060*watchScale.x,2*0.863690*watchScale.y,5,
 SCNVector3(watchContent.position.x,watchContent.position.y,watchContent.position.z+0.410000*watchScale.z+0.08),watchScaled)
let phoneScreen=screen(72.06,158.67,8,SCNVector3(0,81.7,6.8),phone.childNodes[0])
let env=NSImage(size:NSSize(width:1024,height:512))
env.lockFocus()
NSGradient(starting:NSColor(white:0.85,alpha:1),ending:NSColor(white:0.3,alpha:1))!.draw(in:NSRect(x:0,y:0,width:1024,height:512),angle:90)
NSColor(white:1,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:40,y:170,width:240,height:260),xRadius:60,yRadius:60).fill();NSBezierPath(roundedRect:NSRect(x:630,y:220,width:320,height:220),xRadius:80,yRadius:80).fill()
env.unlockFocus()
scene.lightingEnvironment.contents=env;scene.lightingEnvironment.intensity=1.2
let floor = SCNFloor();floor.reflectivity=0
let fm=SCNMaterial();fm.diffuse.contents=NSColor.white;fm.roughness.contents=1;floor.materials=[fm]
let fn=SCNNode(geometry:floor);fn.position.y = -0.2;root.addChildNode(fn)
func light(_ type:SCNLight.LightType, _ intensity:CGFloat, _ pos:SCNVector3) {
 let n=SCNNode();n.light=SCNLight();n.light!.type=type;n.light!.intensity=intensity;n.position=pos
 n.look(at:SCNVector3(0,50,0));root.addChildNode(n)
 if type == .directional { n.light!.castsShadow=true;n.light!.shadowMode = .deferred;n.light!.shadowColor=NSColor(white:0,alpha:0.13);n.light!.shadowRadius=10;n.light!.shadowSampleCount=32;n.light!.shadowMapSize=CGSize(width:4096,height:4096);n.light!.orthographicScale=500;n.light!.zNear=1;n.light!.zFar=1600 }
}
light(.ambient,550,SCNVector3Zero)
light(.directional,1100,SCNVector3(-200,500,350))
light(.omni,700,SCNVector3(350,250,250))
let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.usesOrthographicProjection=true;camera.camera!.orthographicScale=135;camera.camera!.zNear=1;camera.camera!.zFar=2000
camera.position=SCNVector3(0,300,650);camera.look(at:SCNVector3(0,75,0));root.addChildNode(camera)
let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
renderer.scene=scene;renderer.pointOfView=camera;renderer.autoenablesDefaultLighting=false
for language in ["en","zh"] {
watchScreen.diffuse.contents=screenshot(language,CGRect(x:91,y:401,width:250,height:296))
phoneScreen.diffuse.contents=screenshot(language,CGRect(x:487,y:175,width:337,height:736))
let image=renderer.snapshot(atTime:0,with:CGSize(width:2000,height:1000),antialiasingMode:.multisampling4X)
let canvas=NSImage(size:NSSize(width:2000,height:1100))
canvas.lockFocus()
NSColor.white.setFill();NSRect(x:0,y:0,width:2000,height:1100).fill()
image.draw(in:NSRect(x:0,y:100,width:2000,height:1000))
func label(_ text:String,_ x:Double,_ y:Double,_ size:Double,_ color:NSColor,_ weight:NSFont.Weight) {
 let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color]
 let width=(text as NSString).size(withAttributes:attrs).width
 (text as NSString).draw(at:NSPoint(x:x-width/2,y:y),withAttributes:attrs)
}
let ink=NSColor(white:0.12,alpha:1),muted=NSColor(white:0.48,alpha:1)
label("Apple Watch Series 11",402,132,32,ink,.medium)
label("iPhone",870,132,38,ink,.medium)
label("Mac mini",1555,132,38,ink,.medium)
label(language == "en" ? "Capture" : "采集生活",402,81,29,muted,.regular)
label(language == "en" ? "Transcribe" : "本地转录",870,81,29,muted,.regular)
label(language == "en" ? "Run your agent" : "运行你的 Agent",1555,81,29,muted,.regular)
label("→",635,106,34,NSColor(white:0.68,alpha:1),.regular)
label("→",1190,106,34,NSColor(white:0.68,alpha:1),.regular)
canvas.unlockFocus()
let bitmap=NSBitmapImageRep(data:canvas.tiffRepresentation!)!
let path=output.appendingPathComponent("devices-3d-\(language).png")
try bitmap.representation(using:.png,properties:[:])!.write(to:path)
print("Rendered",path.path)
}
