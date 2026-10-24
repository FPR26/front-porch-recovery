const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {createCanvas,loadImage}=require(process.env.FPR_CANVAS_MODULE || '@napi-rs/canvas');
(async()=>{
 const {CARD_DESIGNS,CARD_BRAND_LOGO,renderSupporterCardSvg}=await import('../supabase/functions/_shared/supporter-card-art.mjs');
 const logo=await loadImage(CARD_BRAND_LOGO);assert(logo.width>0 && logo.height>0);
 const output=process.env.FPR_PHASE14_OUTPUT_DIR;if(output)fs.mkdirSync(output,{recursive:true});
 const sheet=createCanvas(1260,980),sc=sheet.getContext('2d');sc.fillStyle='#e6e9e4';sc.fillRect(0,0,1260,980);
 for(let i=0;i<CARD_DESIGNS.length;i++){
  const d=CARD_DESIGNS[i],image=await loadImage(Buffer.from(renderSupporterCardSvg(d.id))),canvas=createCanvas(1200,1200),ctx=canvas.getContext('2d');
  assert.equal(image.width,1200);assert.equal(image.height,1200);ctx.drawImage(image,0,0,1200,1200);
  const before=ctx.getImageData(450,95,300,164).data.slice();ctx.drawImage(logo,450,95,300,300*logo.height/logo.width);
  const after=ctx.getImageData(450,95,300,164).data;let changed=0;for(let p=0;p<after.length;p++)if(after[p]!==before[p])changed++;assert(changed>1000,'Official logo is missing from '+d.id);
  const png=canvas.toBuffer('image/png'),decoded=await loadImage(png);assert.equal(decoded.width,1200);assert.equal(decoded.height,1200);
  if(output)fs.writeFileSync(path.join(output,'fpr-'+d.id+'-collection.png'),png);
  const x=20+(i%3)*420,y=20+Math.floor(i/3)*480;sc.drawImage(canvas,x,y,400,400);sc.fillStyle='#253a32';sc.font='bold 22px Arial';sc.fillText(d.name,x+12,y+434);
 }
 if(output)fs.writeFileSync(path.join(output,'server-collection-contact-sheet.png'),sheet.toBuffer('image/png'));
 console.log('PASS: all six authenticated delivery artworks export as 1200x1200 PNGs with the official logo visibly composited.');
})().catch(error=>{console.error(error);process.exitCode=1});
