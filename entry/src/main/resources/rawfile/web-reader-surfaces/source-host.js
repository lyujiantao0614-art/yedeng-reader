(function () {
  'use strict';
  let worker, epoch=0, sequence=0, stats, pending=new Map(), packetToken=0, textToken=0;
  function close() {
    ++epoch;
    packetToken=0;textToken=0;
    if(worker)worker.terminate();
    worker=null;stats=null;Source.packetResult=null;Source.textResult=null;
    for(const request of pending.values())request.reject(new Error('Obsolete publication'));
    pending.clear();
  }
  function request(kind,payload,transfers) {
    if(!worker)return Promise.reject(new Error('Publication closed'));
    const id=++sequence;
    return new Promise((resolve,reject)=>{
      pending.set(id,{resolve,reject});
      try{worker.postMessage(Object.assign({id,kind},payload),transfers||[]);}
      catch(error){pending.delete(id);reject(error);}
    });
  }
  window.Source={
    packetResult:null,toc:[],close,
    sourceStats:()=>stats,
    open:async function(url,bounds,token){
      close();const revision=epoch;
      try {
        const response=await fetch(url);
        if(!response.ok)throw new Error('Source unavailable');
        const bytes=await response.arrayBuffer();
        if(revision!==epoch)throw new Error('Obsolete publication');
        const workerUrl=URL.createObjectURL(new Blob([window.sourceWorkerCode],{type:'text/javascript'}));
        try{worker=new Worker(workerUrl);}finally{URL.revokeObjectURL(workerUrl);}
        worker.onmessage=event=>{
          if(revision!==epoch)return;
          const request=pending.get(event.data.id);if(!request)return;
          pending.delete(event.data.id);
          if(event.data.failed)request.reject(new Error('Source preparation failed'));
          else request.resolve(event.data.result);
        };
        worker.onerror=()=>{
          if(revision!==epoch)return;
          if(worker)worker.terminate();worker=null;stats=null;
          for(const request of pending.values())request.reject(new Error('Source worker failed'));
          pending.clear();
        };
        const opened=await request('open',{bytes,bounds,limit:6*1024*1024},[bytes]);
        if(revision!==epoch)return;
        if(!ChapterBridge.catalog(JSON.stringify(opened.catalog)))throw new Error('Catalog rejected');
        stats=opened.stats;this.toc=opened.toc;ChapterBridge.sourceDone(token,true);
      }catch(_){if(revision===epoch)ChapterBridge.sourceDone(token,false);}
    },
    packet:async function(index){
      const revision=epoch;
      const result=await request('packet',{index});
      if(revision!==epoch)throw new Error('Obsolete publication');
      stats=result.stats;return result.packet;
    },
    startPacket:function(index,token){
      const revision=epoch;packetToken=token;this.packetResult=null;
      this.packet(index).then(packet=>{
        if(revision===epoch && token===packetToken){this.packetResult=packet;ChapterBridge.packetDone(token,true);}
      },()=>{if(revision===epoch && token===packetToken)ChapterBridge.packetDone(token,false);});
    },
    cancelPacket:function(){packetToken=0;this.packetResult=null;},
    startText:function(index,token){
      const revision=epoch;textToken=token;this.textResult=null;
      this.packet(index).then(packet=>{
        if(revision!==epoch||token!==textToken)return;
        this.textResult=SectionTextMap.extract(packet);
        ChapterBridge.packetDone(token,true);
      }).catch(()=>{if(revision===epoch&&token===textToken)ChapterBridge.packetDone(token,false);});
    }
  };
})();
