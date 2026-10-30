// Build-only geometry and continuous motion from the approved original-brand pebble preview.
export function createPebbleRenderer(THREE, hero) {
  const shapes=[{"center":[263.5,590.0],"outline":[[305.0,737.5],[287.0,736.5],[267.0,726.5],[243.0,707.5],[213.5,676.0],[184.5,636.0],[166.5,603.0],[157.5,573.0],[157.5,554.0],[162.5,537.0],[171.5,522.0],[188.0,505.5],[210.0,490.5],[250.0,467.5],[292.0,447.5],[310.0,442.5],[333.0,442.5],[351.0,450.5],[361.5,462.0],[369.5,485.0],[369.5,513.0],[340.5,637.0],[326.5,714.0],[320.5,727.0],[314.0,733.5]]},{"center":[517.0,550.5],"outline":[[659.0,753.5],[639.0,750.5],[611.0,734.5],[584.5,708.0],[552.5,665.0],[535.0,648.5],[521.0,642.5],[504.0,642.5],[484.0,652.5],[464.5,673.0],[429.5,718.0],[397.0,745.5],[380.0,752.5],[363.0,752.5],[354.0,747.5],[345.5,735.0],[345.5,706.0],[355.5,648.0],[367.5,599.0],[386.5,540.0],[413.5,480.0],[442.5,432.0],[469.5,397.0],[503.0,366.5],[524.0,354.5],[539.0,349.5],[550.0,347.5],[579.0,349.5],[597.0,357.5],[609.0,366.5],[631.5,397.0],[647.5,441.0],[673.5,567.0],[689.5,678.0],[689.5,718.0],[686.5,732.0],[677.0,746.5]]},{"center":[776.0,480.5],"outline":[[739.0,737.5],[726.0,737.5],[718.0,733.5],[713.5,729.0],[708.5,716.0],[703.5,650.0],[670.5,440.0],[669.5,392.0],[671.5,376.0],[675.5,356.0],[687.5,322.0],[701.5,296.0],[718.5,273.0],[743.0,249.5],[775.0,230.5],[794.0,224.5],[821.0,223.5],[839.0,228.5],[855.0,238.5],[868.5,255.0],[878.5,278.0],[882.5,304.0],[882.5,338.0],[873.5,409.0],[846.5,544.0],[832.5,598.0],[816.5,644.0],[796.5,684.0],[776.5,712.0],[760.0,727.5]]}];
  const renderer=new THREE.WebGLRenderer({canvas:hero,antialias:true,alpha:false,preserveDrawingBuffer:true});
      renderer.setClearColor(0x080808,1);
      renderer.outputColorSpace=THREE.SRGBColorSpace;
      renderer.toneMapping=THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure=.95;
      const scene=new THREE.Scene();
      const camera=new THREE.PerspectiveCamera(30,1.15,.1,30);camera.position.set(0,0,7);
      scene.add(new THREE.HemisphereLight(0xffffff,0x827464,1.3));
      const key=new THREE.DirectionalLight(0xfff6e7,3.4);key.position.set(-3,5,7);scene.add(key);
      const fill=new THREE.DirectionalLight(0xffffff,.8);fill.position.set(4,1,4);scene.add(fill);
      const rim=new THREE.DirectionalLight(0xffffff,2);rim.position.set(-3,-1,-5);scene.add(rim);
      const material=new THREE.MeshPhysicalMaterial({color:0xeee7d9,roughness:.68,metalness:0,clearcoat:0});
      function roundedPebble(shape,thickness){
        const border=shape.getPoints(3);
        if(border[0].distanceTo(border[border.length-1])<1e-7)border.pop();
        const triangles=THREE.ShapeUtils.triangulateShape(border,[]);
        const planar=[],lookup=new Map(),faces=[];
        function vertex(p){
          const key=p.x.toFixed(5)+','+p.y.toFixed(5);
          if(!lookup.has(key)){lookup.set(key,planar.length);planar.push(p);}
          return lookup.get(key);
        }
        function subdivide(a,b,c,level){
          if(!level){faces.push([vertex(a),vertex(b),vertex(c)]);return;}
          const ab=a.clone().add(b).multiplyScalar(.5),bc=b.clone().add(c).multiplyScalar(.5),ca=c.clone().add(a).multiplyScalar(.5);
          subdivide(a,ab,ca,level-1);subdivide(ab,b,bc,level-1);subdivide(ca,bc,c,level-1);subdivide(ab,bc,ca,level-1);
        }
        triangles.forEach(f=>subdivide(border[f[0]],border[f[1]],border[f[2]],4));
        const winding=border.reduce((sum,p,j)=>{const q=border[(j+1)%border.length];return sum+p.x*q.y-q.x*p.y;},0)>0?1:-1;
        function edgeDistance(p){
          let best=Infinity,potential=0,nearest=0;
          for(let j=0;j<border.length;j++){
            const a=border[j],b=border[(j+1)%border.length],dx=b.x-a.x,dy=b.y-a.y;
            const length=dx*dx+dy*dy;
            const t=length?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)):0;
            const squared=(p.x-a.x-t*dx)**2+(p.y-a.y-t*dy)**2;
            if(squared<best){best=squared;nearest=j;}
            potential+=Math.sqrt(length)/Math.max(squared,1e-16);
          }
          return{distance:Math.sqrt(best),fullness:Math.pow(potential,-.25),nearest};
        }
        const distances=planar.map(edgeDistance),maximum=Math.max(...distances.map(d=>d.fullness));
        const positions=[],normals=[],front=[],back=[];
        planar.forEach((p,j)=>{
          const data=distances[j],d=data.distance;
          // Blend contributions from the entire rim so the stone has no medial-axis ridges.
          const h=d<1e-7?0:thickness*data.fullness/maximum;
          front[j]=positions.length/3;positions.push(p.x,p.y,h);
          if(h===0){
            back[j]=front[j];
            const a=border[data.nearest],b=border[(data.nearest+1)%border.length];
            const normal=new THREE.Vector3((b.y-a.y)*winding,(a.x-b.x)*winding,0).normalize();
            normals.push(normal.x,normal.y,normal.z);
          }else{
            const epsilon=Math.min(d*.2,1e-4);
            const dx=(edgeDistance({x:p.x+epsilon,y:p.y}).fullness-edgeDistance({x:p.x-epsilon,y:p.y}).fullness)*thickness/maximum/(2*epsilon);
            const dy=(edgeDistance({x:p.x,y:p.y+epsilon}).fullness-edgeDistance({x:p.x,y:p.y-epsilon}).fullness)*thickness/maximum/(2*epsilon);
            const normal=new THREE.Vector3(-dx,-dy,1).normalize();
            normals.push(normal.x,normal.y,normal.z);
            back[j]=positions.length/3;positions.push(p.x,p.y,-h);normals.push(normal.x,normal.y,-normal.z);
          }
        });
        const indices=[];
        faces.forEach(face=>{
          let[a,b,c]=face;
          const pa=planar[a],pb=planar[b],pc=planar[c];
          if((pb.x-pa.x)*(pc.y-pa.y)-(pb.y-pa.y)*(pc.x-pa.x)<0)[b,c]=[c,b];
          indices.push(front[a],front[b],front[c],back[a],back[c],back[b]);
        });
        const geometry=new THREE.BufferGeometry();
        geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setIndex(indices);
        geometry.setAttribute('normal',new THREE.Float32BufferAttribute(normals,3));geometry.computeBoundingSphere();return geometry;
      }
      const homes=[];
      const stones=shapes.map((data,i)=>{
        const points=data.outline.map(p=>new THREE.Vector2((p[0]-data.center[0])/260,(data.center[1]-p[1])/260));
        const shape=new THREE.Shape();
        const n=points.length;
        const first=points[0].clone().add(points[n-1]).multiplyScalar(.5);
        shape.moveTo(first.x,first.y);
        points.forEach((p,j)=>{const next=p.clone().add(points[(j+1)%n]).multiplyScalar(.5);shape.quadraticCurveTo(p.x,p.y,next.x,next.y);});
        shape.closePath();
        const geometry=roundedPebble(shape,[.33,.30,.36][i]);
        const mesh=new THREE.Mesh(geometry,material);
        const home=new THREE.Vector3((data.center[0]-512)/260,(512-data.center[1])/260,0);
        homes.push(home);mesh.position.copy(home);scene.add(mesh);return mesh;
      });

      function motionAt(theta,i,amount){
        const h=homes[i],s=Math.sin(theta),c=Math.cos(theta),s2=Math.sin(2*theta),c2=Math.cos(2*theta);
        if(i===0)return{
          pose:{x:h.x+.90*(1-c)*amount,y:h.y+.48*s*amount,z:(1.65*s+.35*(1-c))*amount,rx:theta,ry:.25*s,rz:.08*s},
          tangent:{x:.90*s*amount,y:.48*c*amount,z:(1.65*c+.35*s)*amount,rx:1,ry:.25*c,rz:.08*c}
        };
        if(i===1)return{
          pose:{x:h.x+.52*s*amount,y:h.y+.46*s2*amount,z:(.12*s2+.05*(1-c))*amount,rx:.22*s,ry:-theta,rz:-.07*s},
          tangent:{x:.52*c*amount,y:.92*c2*amount,z:(.24*c2+.05*s)*amount,rx:.22*c,ry:-1,rz:-.07*c}
        };
        return{
          pose:{x:h.x-.90*(1-c)*amount,y:h.y-.48*s*amount,z:(-2.10*s-.35*(1-c))*amount,rx:-theta,ry:.22*s,rz:-.08*s},
          tangent:{x:-.90*s*amount,y:-.48*c*amount,z:(-2.10*c-.35*s)*amount,rx:-1,ry:.22*c,rz:-.08*c}
        };
      }

  renderer.setSize(64,56,false);
  camera.aspect=64/56;camera.updateProjectionMatrix();
  return theta => {
    stones.forEach((mesh,i)=>{
      const p=motionAt(theta,i,1).pose;
      mesh.position.set(p.x,p.y,p.z);mesh.rotation.set(p.rx,p.ry,p.rz);
    });
    renderer.render(scene,camera);
    return hero.toDataURL('image/png');
  };
}
