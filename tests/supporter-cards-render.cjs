const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {createCanvas,loadImage}=require(process.env.FPR_CANVAS_MODULE || '@napi-rs/canvas');
(async()=>{
 const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
 const start=html.indexOf('const SUPPORTER_WORKBOOK ='),end=html.indexOf('(function initSupporterPreview(){',start);
 const {designs,draw,workbook}=vm.runInNewContext(html.slice(start,end)+';({designs:SUPPORTER_CARD_DESIGNS,draw:drawSupporterCard,workbook:SUPPORTER_WORKBOOK})');
 const logo=await loadImage(html.match(/brandLogoUrl:\s*'([^']+)'/)[1]);
 assert.equal(workbook.length,7);assert(workbook.every(d=>d.prompts.length===3));assert.equal(designs.length,6);assert.equal(new Set(designs.map(d=>d.id)).size,6);
 const output=process.env.FPR_PHASE13_OUTPUT_DIR;if(output)fs.mkdirSync(output,{recursive:true});
 const sheets=[true,false].map(()=>createCanvas(1260,980));
 for(let index=0;index<designs.length;index++){
  const d=designs[index];assert(html.includes('data-supporter-card="'+d.id+'"'));assert(html.includes('data-supporter-download="'+d.id+'"'));
  for(const preview of [true,false]){
   const canvas=createCanvas(1200,1200),ctx=canvas.getContext('2d'),texts=[],fillText=ctx.fillText.bind(ctx);
   ctx.fillText=(text,x,y)=>{assert(ctx.measureText(text).width<=1080,'Text exceeds safe width: '+text);assert(y>=80 && y<=1120);texts.push(text);fillText(text,x,y)};
   draw(ctx,logo,d.id,preview);
   assert.equal(texts.includes('DESIGN PREVIEW · SAMPLE'),preview);assert(texts.includes('FRONT PORCH RECOVERY'));assert(texts.includes('fpr26.github.io/front-porch-recovery'));
   const png=canvas.toBuffer('image/png'),decoded=await loadImage(png);assert.equal(decoded.width,1200);assert.equal(decoded.height,1200);
   if(output)fs.writeFileSync(path.join(output,'fpr-'+d.id+(preview?'-sample':'-collection')+'.png'),png);
   const sheet=sheets[preview?0:1],sc=sheet.getContext('2d'),x=20+(index%3)*420,y=20+Math.floor(index/3)*480;
   sc.fillStyle='#ffffff';sc.fillRect(x,y,400,460);sc.drawImage(canvas,x,y,400,400);sc.fillStyle='#172b23';sc.font='bold 22px Arial';sc.fillText(d.name,x+12,y+434);
  }
 }
 if(output){fs.writeFileSync(path.join(output,'sample-collection-contact-sheet.png'),sheets[0].toBuffer('image/png'));fs.writeFileSync(path.join(output,'clean-collection-contact-sheet.png'),sheets[1].toBuffer('image/png'));}
 console.log('PASS: six distinct 1200x1200 designs; sample labels on every public preview; clean exports separate; official logo; safe text bounds; six matching download controls; seven three-prompt workbook reflections.');
})().catch(error=>{console.error(error);process.exitCode=1});
