(function () {
  'use strict';
  var contents, slot = 0, commits = 0, firstDocument;
  var selectionSignature = '', selectionTouchActive = false, selectionAtPointerStart = false,
    selectionAdjusting = false, selectionChangeRevision = 0;
  var frame = document.querySelector('iframe');
  var paginationMode = 'scroll', clipWindow, pageOffset = 0, closedPresentation = -1, latestPresentation = -1;
  function closePresentation(token) {
    if (Number.isSafeInteger(token)) {
      closedPresentation = Math.max(closedPresentation, token);
      latestPresentation = Math.max(latestPresentation, token);
    }
    pageOffset = 0;
  }
  function pageLeft() { return paginationMode === 'clip' && Surface.state ? Surface.state.unit * Surface.state.viewport : scrollX; }
  function renderPage(unit) {
    if (paginationMode === 'clip') {
      Surface.state.unit = unit;
      frame.style.transform = 'translateX(' + (-unit * Surface.state.viewport + pageOffset) + 'px)';
    } else window.scrollTo(unit * innerWidth, 0);
  }
  var removeBridgeListeners, sourceEpoch = 0;
  var sourceWorker, workerSequence=0, workerPending=new Map(), workerStats;
  var scriptLoads=new Map();
  var pendingResize, resizeObserver;
  var latestConfigureToken = 0;
  var loadEpoch = 0;
  var textMarks = new Map();
  var highlightName = 'harmony-reader-highlight', noteName = 'harmony-reader-note';
  var readerSettings = {fontScale:1,lineSpacing:1.5,pageMarginVp:20,theme:'light',columnMode:'auto'};
  function setReaderSettings(value) {
    if (!value || !Number.isFinite(value.fontScale) || !Number.isFinite(value.lineSpacing) ||
      !Number.isFinite(value.pageMarginVp)) throw new Error('Invalid reader settings');
    readerSettings = {fontScale:Math.max(0.8,Math.min(1.6,value.fontScale)),
      lineSpacing:Math.max(1.2,Math.min(2,value.lineSpacing)),
      pageMarginVp:Math.max(8,Math.min(40,value.pageMarginVp)),
      theme:['light','dark','eye-comfort'].includes(value.theme)?value.theme:'light',
      columnMode:value.columnMode==='single'?'single':'auto'};
    applyReaderCanvas();
  }
  function applyReaderCanvas() {
    var canvas=readerSettings.theme==='dark'?'#172029':
      readerSettings.theme==='eye-comfort'?'#e8dfc9':'#fafbfc';
    document.documentElement.style.backgroundColor=canvas;
    document.body.style.backgroundColor=canvas;
    frame.style.backgroundColor=canvas;
  }
  function applyReaderTheme(doc) {
    var style=doc.getElementById('harmony-reader-theme');
    if (!style) {style=doc.createElementNS('http://www.w3.org/1999/xhtml','style');
      style.id='harmony-reader-theme';doc.head.appendChild(style);}
    var colors=readerSettings.theme==='dark'?['#172029','#eef3f8','#a2caff']:
      readerSettings.theme==='eye-comfort'?['#e8dfc9','#38392f','#765335']:
      ['#fafbfc','#18212b','#185bb5'];
    style.textContent='html,body{background:'+colors[0]+'!important;color:'+colors[1]+'!important}'+
      'a{color:'+colors[2]+'!important}';
    var markStyle=doc.getElementById('harmony-reader-mark-style');
    if (markStyle) markStyle.textContent=markStyle.textContent.replace(
      /text-decoration-color: (?:#b67423|currentColor);/,
      'text-decoration-color: '+(readerSettings.theme==='eye-comfort'?'#b67423':'currentColor')+';');
  }
  function applyReaderStyle(doc) {
    var style=doc.getElementById('harmony-reader-settings');
    if (!style) {style=doc.createElementNS('http://www.w3.org/1999/xhtml','style');
      style.id='harmony-reader-settings';doc.head.appendChild(style);}
    style.textContent='body{font-size:'+Math.round(18*readerSettings.fontScale)+'px!important;line-height:'+readerSettings.lineSpacing+
      '!important;box-sizing:border-box!important}';
    applyReaderTheme(doc);
  }
  function applyBodyTypography(doc) {
    // Publisher rules on text children do not inherit body typography. Override
    // ordinary text only; never rewrite the source tree or blanket-style '*'.
    var view = doc.defaultView;
    if (view.getComputedStyle(doc.body).writingMode !== 'horizontal-tb') return;
    var specialTags = /^(h[1-6]|table|pre|code|kbd|samp|svg|math|figure|figcaption)$/i;
    var specialClass = /(?:^|[\s_-])(?:poem|poetry|verse|stanza|haiku|lyrics)(?:$|[\s_-])/i;
    function protectedText(element) {
      for (var node = element; node && node !== doc.body; node = node.parentElement) {
        if (specialTags.test(node.localName) || specialClass.test(node.getAttribute('class') || '') ||
          /(?:poem|poetry|verse)/i.test(node.getAttribute('epub:type') || '')) return true;
        var space = view.getComputedStyle(node).whiteSpace;
        if (space === 'pre' || space === 'pre-wrap' || space === 'break-spaces') return true;
      }
      return false;
    }
    Array.prototype.forEach.call(doc.querySelectorAll('p,li,div,span'), function (element) {
      if (protectedText(element)) return;
      // A structural div can contain headings or special layouts. Only its
      // leaf text containers are candidates; paragraphs/lists handle themselves.
      if (element.localName === 'div' && element.querySelector('p,li,div,h1,h2,h3,h4,h5,h6,table,pre,figure,svg,math')) return;
      element.style.setProperty('line-height', String(readerSettings.lineSpacing), 'important');
      element.style.setProperty('font-size', element.localName === 'span' ? 'inherit' :
        Math.round(18 * readerSettings.fontScale) + 'px', 'important');
    });
  }
  function installReadableOverflow(doc) {
    // Match the ordinary reader before measuring columns or publishing a CFI.
    Array.prototype.forEach.call(doc.querySelectorAll('table, th, td, pre'), function (element) {
      var tag = String(element.tagName).toUpperCase();
      if (tag === 'TABLE') {
        element.style.setProperty('width', '100%', 'important');
        element.style.setProperty('max-width', '100%', 'important');
        element.style.setProperty('table-layout', 'fixed', 'important');
      } else {
        element.style.setProperty('overflow-wrap', 'anywhere', 'important');
        if (tag === 'PRE') {
          element.style.setProperty('white-space', 'pre-wrap', 'important');
          element.style.setProperty('max-width', '100%', 'important');
        }
      }
    });
  }
  function columnGeometry(width) {
    // epub.js reserves half the gap on both outer edges, including in single-column mode.
    return HarmonyReaderLayoutContract.surfaceColumnGeometry(width,readerSettings);
  }
  function cancelResize(){
    if(pendingResize){
      removeEventListener('resize',pendingResize);
      if(window.visualViewport)window.visualViewport.removeEventListener('resize',pendingResize);
    }
    if(resizeObserver){resizeObserver.disconnect();resizeObserver=null;}
    pendingResize=null;
  }
  function watchResize(check){
    pendingResize=check;
    addEventListener('resize',check);
    if(window.visualViewport)window.visualViewport.addEventListener('resize',check);
    if(window.ResizeObserver){
      resizeObserver=new ResizeObserver(function(){if(pendingResize)pendingResize();});
      resizeObserver.observe(document.documentElement);
    }
    check();
  }
  function scripts(names){return Promise.all(names.map(function(name){
    if(!scriptLoads.has(name))scriptLoads.set(name,new Promise(function(resolve,reject){
      var script=document.createElement('script');script.src=name;
      script.onload=function(){script.remove();resolve();};
      script.onerror=function(){script.remove();scriptLoads.delete(name);reject(new Error('Local source script unavailable'));};
      document.head.appendChild(script);
    }));return scriptLoads.get(name);
  }));}
  function workerRequest(kind,payload,transfers) {
    var id=++workerSequence;
    return new Promise(function(resolve,reject){workerPending.set(id,{resolve:resolve,reject:reject});sourceWorker.postMessage(Object.assign({id:id,kind:kind},payload),transfers||[]);});
  }
  function closeWorker(){if(sourceWorker)sourceWorker.terminate();sourceWorker=null;workerPending.forEach(function(p){p.reject(new Error('Obsolete publication'));});workerPending.clear();}
  function clearTextMarks(){
    if(contents && contents.window.CSS && contents.window.CSS.highlights) {
      contents.window.CSS.highlights.delete(highlightName);
      contents.window.CSS.highlights.delete(noteName);
    }
    textMarks.clear();
  }
  function refreshTextMarks() {
    if (!contents || !contents.window.CSS || !contents.window.CSS.highlights || !contents.window.Highlight) return false;
    var css=contents.window.CSS, Highlight=contents.window.Highlight;
    var highlights=[], notes=[];
    textMarks.forEach(function (value) { notes.push(...value.notes);highlights.push(...value.highlights); });
    if (highlights.length) css.highlights.set(highlightName,new Highlight(...highlights));
    else css.highlights.delete(highlightName);
    if (notes.length) css.highlights.set(noteName,new Highlight(...notes));
    else css.highlights.delete(noteName);
    return true;
  }
  function firstContentRange(doc) {
    var body = doc.body || doc.documentElement.querySelector('body');
    var walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT), node;
    while ((node = walker.nextNode())) {
      if (!node.data.trim() || node.parentElement.closest('script,style')) continue;
      var range = doc.createRange(); range.setStart(node,0); range.setEnd(node, Math.min(8,node.length)); return range;
    }
    var range = doc.createRange();
    var element = body.querySelector('img,svg') || body.firstElementChild;
    if (!element) throw new Error('Empty chapter');
    range.selectNode(element); return range;
  }
  function contentCfi(doc, base) {
    var range = firstContentRange(doc);
    if (range.startContainer.nodeType === Node.TEXT_NODE) return new ePub.CFI(range, base).toString();
    return new ePub.CFI((doc.body || doc.querySelector('body')).querySelector('img,svg'), base).toString();
  }
  // Pinned Contents registers MediaQueryList callbacks but destroy() never
  // removes them. The iframe Window survives chapter replacement, so those
  // callbacks otherwise retain each old Contents and its detached body.
  class ChapterContents extends ePub.Contents {
    mediaQueryListeners() {
      this.mediaBindings = [];
      this.mediaTimers = new Set();
      var sheets = this.document.styleSheets;
      for (var i = 0; i < sheets.length; i++) {
        var rules;
        try { rules = sheets[i].cssRules; } catch (_) { return; }
        if (!rules) return;
        for (var j = 0; j < rules.length; j++) {
          if (!rules[j].media) continue;
          var query = this.window.matchMedia(rules[j].media.mediaText);
          var listener = (event) => {
            if (!event.matches || this._expanding) return;
            var timer = setTimeout(() => { this.mediaTimers.delete(timer); this.expand(); }, 1);
            this.mediaTimers.add(timer);
          };
          query.addListener(listener);
          this.mediaBindings.push({query:query,listener:listener});
        }
      }
    }
    destroy() {
      this.mediaBindings.forEach(binding => binding.query.removeListener(binding.listener));
      this.mediaBindings = [];
      this.mediaTimers.forEach(timer => clearTimeout(timer));
      this.mediaTimers.clear();
      super.destroy();
    }
  }
  window.Surface = {
    setPaginationMode: function (mode) {
      if (!['scroll','clip'].includes(mode) || (contents && mode !== paginationMode)) throw new Error('Invalid pagination mode');
      if (mode === 'clip' && !clipWindow) {
        if (!CSS.supports('overflow','clip')) throw new Error('Clipped pagination unavailable');
        clipWindow = document.createElement('div');
        clipWindow.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;overflow:clip;contain:paint';
        frame.parentNode.insertBefore(clipWindow,frame);clipWindow.appendChild(frame);
      }
      paginationMode = mode;
    },
    // Driven only by the existing App Pan/Animator. A completed token cannot
    // reapply queued frames after settle, cancellation, load or reflow.
    presentPage: function (unit, offset, token, settled, expectedVersion) {
      if (paginationMode === 'clip' && this.state &&
        (token <= closedPresentation || expectedVersion !== undefined && expectedVersion !== this.state.surfaceVersion)) return true;
      if (paginationMode !== 'clip' || !this.state || !Number.isInteger(unit) || unit < 0 || unit >= this.state.units ||
        !Number.isFinite(offset) || Math.abs(offset) > this.state.viewport + 2 || !Number.isSafeInteger(token)) return false;
      if (token <= closedPresentation) return true;
      if (!settled && unit !== this.state.unit) return false;
      closedPresentation = Math.max(closedPresentation, token - 1);
      latestPresentation = Math.max(latestPresentation, token);
      if (settled) closePresentation(token); else pageOffset = offset;
      renderPage(unit);
      return true;
    },
    exportReady: false,
    exportLocal: async function (url, bounds, token) {
      this.exportFailed=false;
      try {
        const response=await fetch(url);
        if(!response.ok)throw new Error('Local archive unavailable');
        await this.exportPublication(await response.arrayBuffer(),bounds);
        ChapterBridge.sourceDone(token,true);
      } catch (_) { this.exportFailed=true; ChapterBridge.sourceDone(token,false); }
    },
    exportPublication: async function (bytes, bounds) {
      var epoch = ++sourceEpoch;
      this.exportReady = false; this.chapterCount = 0;
      this.packetDone = false; this.packetResult = null; workerStats = null;
      this.sourceLimit = 6 * 1024 * 1024;
      closeWorker();
      await scripts(['source-worker-bundle.js']);
      if(epoch!==sourceEpoch)throw new Error('Obsolete publication');
      this.stage='worker-open';
      var workerUrl=URL.createObjectURL(new Blob([window.sourceWorkerCode],{type:'text/javascript'}));
      try{sourceWorker=new Worker(workerUrl);}finally{URL.revokeObjectURL(workerUrl);}
      sourceWorker.onmessage=function(event){var request=workerPending.get(event.data.id);if(!request)return;workerPending.delete(event.data.id);if(event.data.failed)request.reject(new Error('Source preparation failed'));else request.resolve(event.data.result);};
      sourceWorker.onerror=function(){workerPending.forEach(function(p){p.reject(new Error('Source worker failed'));});workerPending.clear();};
      var transfer=bytes instanceof ArrayBuffer?bytes:bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);
      var opened=await workerRequest('open',{bytes:transfer,limit:this.sourceLimit,bounds:bounds},[transfer]);
      if(epoch!==sourceEpoch)throw new Error('Obsolete publication');
      if(!ChapterBridge.catalog(JSON.stringify(opened.catalog)))throw new Error('Resource catalog rejected');
      workerStats=opened.stats;this.chapterCount=workerStats.chapterCount;this.toc=opened.toc;this.exportReady=true;
    },
    getPacket: function (index) {
      var epoch = sourceEpoch;
      if(!sourceWorker)return Promise.reject(new Error('Publication closed'));
      return workerRequest('packet',{index:index}).then(function(result){
        if(epoch!==sourceEpoch)throw new Error('Obsolete publication');workerStats=result.stats;
        return result.packet;
      });
    },
    startPacket: function(index,token) {
      this.packetDone=false;this.packetResult=null;this.packetFailed=false;
      var epoch=sourceEpoch;
      this.getPacket(index).then(function(packet){if(epoch===sourceEpoch){Surface.packetResult=packet;Surface.packetDone=true;ChapterBridge.packetDone(token,true);}},function(){if(epoch===sourceEpoch){Surface.packetFailed=true;Surface.packetDone=true;ChapterBridge.packetDone(token,false);}});
    },
    sourceStats: function() {return workerStats;},
    load: async function (packet, id, wide, resourceRoot, initialAtEnd, session, surfaceVersion) {
      const epoch=++loadEpoch;
      const valid=()=>{if(epoch!==loadEpoch)throw new Error('Obsolete chapter');};
      cancelResize();
      this.stage = 'document';
      var started = Date.now();
      slot = id;
      selectionSignature = ''; selectionTouchActive = false; selectionAtPointerStart = false;
      selectionAdjusting = false; selectionChangeRevision++;
      this.anchor = null; this.anchorUnit = undefined;
      var stages = {};
      if (paginationMode === 'clip') { pageOffset = 0; frame.style.transform = 'none'; }
      window.scrollTo(0, 0); frame.style.width = '100%';
      document.body.style.overflow = wide ? 'visible' : 'hidden';
      document.querySelector('meta[name=viewport]').content = wide ? 'width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1' : 'width=device-width,initial-scale=1';
      if (removeBridgeListeners) { removeBridgeListeners(); removeBridgeListeners = null; }
      clearTextMarks();
      if (contents) { contents.destroy(); contents=null; }
      stages.resetMs = Date.now() - started;
      var parsed = new DOMParser().parseFromString(packet.html, packet.parseMode || 'application/xhtml+xml');
      if (parsed.querySelector('parsererror')) throw new Error('Invalid chapter XML');
      var originalCfi=packet.originalCfi;
      if(packet.parseMode==='text/html'){
        var referenceDoc=resourceRoot?parsed:new DOMParser().parseFromString(packet.originalHtml,'text/html');
        originalCfi=contentCfi(referenceDoc,packet.base);
        referenceDoc=null;
      }
      var doc = frame.contentDocument;
      if(resourceRoot){
        for(const old of parsed.querySelectorAll('base'))old.remove();
        const base=parsed.createElementNS('http://www.w3.org/1999/xhtml','base');
        base.setAttribute('href',resourceRoot+packet.resourcePath);parsed.querySelector('head').prepend(base);
      }
      // Attach the complete XML tree without HTML parsing's implicit tbody nodes.
      // Keep the existing iframe document so ArkWeb does not navigate a blob frame.
      var root = doc.importNode(parsed.documentElement, true);
      var imageFailures = 0;
      var pendingResources = Array.from(root.querySelectorAll('link[rel="stylesheet"],img,image')).map(function (element) {
        return new Promise(function (resolve, reject) {
          element.addEventListener('load', function () { resolve(); }, {once:true});
          element.addEventListener('error', function () {
            if (element.localName === 'img' || element.localName === 'image') { imageFailures++; resolve(); }
            else reject(new Error('Stylesheet failed'));
          }, {once:true});
        });
      });
      // The iframe Document survives chapter replacement; its text-node map does not.
      RangeAnchors.invalidate(doc);
      doc.replaceChild(root, doc.documentElement);
      applyReaderStyle(doc);
      this.stage = 'resources';
      await Promise.all(pendingResources);
      valid();
      applyBodyTypography(doc);
      stages.documentMs = Date.now() - started;
      if (frame.contentDocument !== doc || doc.querySelectorAll('p').length !== packet.paragraphs) throw new Error('Incomplete chapter document');
      installReadableOverflow(doc);
      this.stage = 'fonts';
      // Layout starts actual used font loads before awaiting FontFaceSet readiness.
      if (doc.fonts.size > 0) { doc.body.getBoundingClientRect(); await doc.fonts.ready; }
      valid();
      this.imageStatus = Array.from(doc.images).map(function (img) { return {complete:img.complete,width:img.naturalWidth}; });
      stages.resourcesMs = Date.now() - started;
      this.stage = 'layout';
      contents = new ChapterContents(doc, doc.body, packet.base, packet.index);
      stages.contentsMs = Date.now() - started;
      var width = innerWidth, height = innerHeight, geometry = columnGeometry(width);
      contents.columns(width, height, geometry.width, geometry.gap, 'ltr');
      stages.columnsMs = Date.now() - started;
      var measured = contents.textWidth();
      stages.layoutMs = Date.now() - started;
      if (wide) frame.style.width = Math.ceil(measured / width) * width + 'px';
      var range = firstContentRange(doc);
      var cfi = contentCfi(doc, packet.base), restored = contents.range(cfi);
      firstDocument = doc;
      this.state = { index: packet.index, href: packet.href, base: packet.base, session:session||0, surfaceVersion:surfaceVersion||0, originalCfi: cfi, units: Math.ceil(measured / width), viewport: width, height: height, complete: true, imageFailures: imageFailures, images: doc.images.length, fontsLoaded: doc.fonts.status === 'loaded', paragraphs: packet.paragraphs, cfiRoundTrip: !!restored && (range.startContainer.nodeType === Node.TEXT_NODE ? restored.toString() === range.toString() : !!doc.body.querySelector('img,svg') && (doc.body.querySelector('img,svg') === restored.startContainer || doc.body.querySelector('img,svg').contains(restored.startContainer))), baseMatches: cfi.indexOf(packet.base) >= 0, originalCfiMatches: cfi === originalCfi, loads: ++commits };
      function publishSelection() {
        var selection = doc.getSelection();
        if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return;
        var text = selection.toString().trim();
        if (!text || text.length > RangeAnchors.QUOTE_LIMIT) return;
        var range = selection.getRangeAt(0), cfi = contents.cfiFromRange(range);
        if (!cfi || cfi.length > 4096) return;
        var signature = cfi + ':' + text;
        if (signature === selectionSignature && !selectionAdjusting) return;
        var frameRect = frame.getBoundingClientRect();
        var rect = Array.from(range.getClientRects()).find(function (item) { return item.width>0 && item.height>0 &&
          (paginationMode === 'clip' ? item.right+frameRect.left>0 && item.left+frameRect.left<innerWidth : item.left>=0 && item.left<innerWidth); }) || range.getBoundingClientRect();
        selectionSignature = signature;
        selectionAdjusting = false;
        ChapterBridge.selectionEvent(slot, JSON.stringify({text:text,cfi:cfi,
          left:frameRect.left+rect.left,top:frameRect.top+rect.top,
          width:rect.width,height:rect.height,viewportWidth:innerWidth,viewportHeight:innerHeight}));
      }
      function selectionChanged() {
        var revision = ++selectionChangeRevision;
        var selection = doc.getSelection(), selected = !!selection && !selection.isCollapsed;
        if (!selected) { selectionSignature = ''; selectionAdjusting = false; }
        ChapterBridge.selection(slot, selected);
        if (!selected) return;
        var signature = '';
        if (selection.rangeCount === 1) {
          var text = selection.toString().trim(), cfi = contents.cfiFromRange(selection.getRangeAt(0));
          if (text && cfi) signature = cfi + ':' + text;
        }
        if (signature && signature === selectionSignature && !selectionTouchActive && !selectionAdjusting) return;
        if (selectionTouchActive || selectionSignature) {
          selectionAdjusting = true;
          ChapterBridge.adjusting(slot);
          if (!selectionTouchActive) {
            var stableFrames = 0;
            function settleWhenStable() {
              if (revision !== selectionChangeRevision || selectionTouchActive || !selectionAdjusting) return;
              if (++stableFrames < 6) requestAnimationFrame(settleWhenStable);
              else publishSelection();
            }
            requestAnimationFrame(settleWhenStable);
          }
        } else {
          requestAnimationFrame(publishSelection);
        }
      }
      function pointerStarted(event) {
        if (event.pointerType !== 'touch') selectionAtPointerStart = !doc.getSelection().isCollapsed;
      }
      function touchStarted(event) {
        selectionAtPointerStart = !doc.getSelection().isCollapsed;
        selectionTouchActive = true;
        if (selectionAtPointerStart) ChapterBridge.adjusting(slot);
        ChapterBridge.block(slot, !!event.target.closest('a,pre'));
      }
      function touchEnded() {
        selectionTouchActive = false; ChapterBridge.block(slot, false);
        requestAnimationFrame(publishSelection);
      }
      this.selectionSettled = function () {
        selectionTouchActive = false;
        requestAnimationFrame(publishSelection);
      };
      function tapped(event) {
        var selectedAtStart = selectionAtPointerStart;
        selectionAtPointerStart = false;
        if (selectedAtStart) {
          if (doc.getSelection().isCollapsed) ChapterBridge.selection(slot, false);
          return;
        }
        var anchor = event.target.closest('a');
        if (anchor) {
          event.preventDefault(); event.stopPropagation();
          var target = HarmonyReaderNavigationContract.classifyLink(anchor.getAttribute('href'),
            Surface.state.href, anchor.getAttribute('epub:type') || anchor.getAttributeNS('http://www.idpf.org/2007/ops','type'),
            anchor.getAttribute('role'));
          ChapterBridge.link(slot, JSON.stringify(target));
          return;
        }
        if (event.target.closest('pre') || !doc.getSelection().isCollapsed) return;
        var hit=null;
        textMarks.forEach(function (value,id) {
          if (hit) return;
          for (var rect of value.ranges.flatMap(function(range){return Array.from(range.getClientRects());})) {
            if (event.clientX>=rect.left && event.clientX<rect.right &&
              event.clientY>=rect.top && event.clientY<rect.bottom) {hit={id:id,rect:rect};break;}
          }
        });
        if (hit) {
          var frameRect=frame.getBoundingClientRect();
          ChapterBridge.markTap(slot,JSON.stringify({markId:hit.id,
            left:frameRect.left+hit.rect.left,top:frameRect.top+hit.rect.top,
            width:hit.rect.width,height:hit.rect.height,
            viewportWidth:innerWidth,viewportHeight:innerHeight}));
          return;
        }
        var fraction = (event.clientX - (paginationMode === 'clip' ? pageLeft() : window.scrollX)) / window.innerWidth;
        ChapterBridge.tap(slot, fraction < 0.30 ? -1 : (fraction > 0.70 ? 1 : 0));
      }
      doc.addEventListener('selectionchange', selectionChanged);
      doc.addEventListener('pointerdown', pointerStarted);
      doc.addEventListener('touchstart', touchStarted, {passive:true});
      doc.addEventListener('touchend', touchEnded, {passive:true});
      doc.addEventListener('touchcancel', touchEnded, {passive:true});
      doc.addEventListener('mouseup', touchEnded);
      doc.addEventListener('click', tapped);
      removeBridgeListeners = function () {
        doc.removeEventListener('selectionchange', selectionChanged);
        doc.removeEventListener('pointerdown', pointerStarted);
        doc.removeEventListener('touchstart', touchStarted);
        doc.removeEventListener('touchend', touchEnded);
        doc.removeEventListener('touchcancel', touchEnded);
        doc.removeEventListener('mouseup', touchEnded);
        doc.removeEventListener('click', tapped);
      };
      var initialUnit = initialAtEnd ? this.state.units - 1 : 0;
      renderPage(initialUnit);
      if (paginationMode !== 'clip') this.state.unit = Math.round(scrollX / width);
      this.state.stages = stages; this.state.visibility = document.visibilityState;
      this.state.preparationStart = started; this.state.preparationEnd = Date.now();
      this.stage = 'complete';
      return this.state;
    },
    cancelLoad: function () { ++loadEpoch; this.loadDone=true; this.loadResult={complete:false,cancelled:true}; },
    clearSelection: function () {
      if (frame.contentDocument) frame.contentDocument.getSelection().removeAllRanges();
      selectionSignature = '';
      selectionAdjusting = false;
      selectionChangeRevision++;
    },
    selectionSettled: function () {},
    selectionContext: function (marks, excludeMarkId, bookId) {
      if (!contents || !firstDocument || frame.contentDocument !== firstDocument) return null;
      var selection = firstDocument.getSelection();
      if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return null;
      var text = selection.toString().trim();
      if (!text || text.length > RangeAnchors.QUOTE_LIMIT) return null;
      var range = selection.getRangeAt(0), cfi = contents.cfiFromRange(range);
      if (selectionSignature !== cfi + ':' + text) return null;
      var block = range.startContainer.nodeType === Node.ELEMENT_NODE ? range.startContainer : range.startContainer.parentElement;
      block = block && block.closest('p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,figcaption,dt,dd');
      var anchor = {}, conflict, combined;
      try {
        var original = RangeAnchors.anchor(contents,range);
        anchor = {rangeText:original.exactText,prefix:original.prefix,suffix:original.suffix,quoteScope:original.quoteScope};
        if (marks !== undefined) combined=RangeAnchors.union(contents,range,marks,this.state.href,this.state.base,bookId,excludeMarkId);
      } catch (_) { conflict='unavailable'; }
      return Object.assign({text:text,cfi:cfi,markConflict:conflict,rangeUnion:combined,
        currentText:(block ? block.textContent : text).trim().slice(0,2000)},anchor);
    },
    verifyTextRange: function (mark) {
      return !!contents && !!this.state && frame.contentDocument===firstDocument &&
        RangeAnchors.verify(contents,mark,this.state.href,this.state.base);
    },
    resolveTextRange: function (mark, expectedSession) {
      if (!this.state || this.state.session!==expectedSession || !contents || frame.contentDocument!==firstDocument)
        return {status:'orphaned',reason:'unavailable'};
      return RangeAnchors.resolve(contents,mark,this.state.href,this.state.base);
    },
    drawVerifiedTextMark: function (mark, expectedSession) {
      if (!mark || typeof mark.markId !== 'string' || !mark.markId || mark.markId.length>160 ||
        (mark.kind!==undefined && mark.kind!=='highlight' && mark.kind!=='note') ||
        !this.state || this.state.session!==expectedSession ||
        (textMarks.size>=100 && !textMarks.has(mark.markId))) return false;
      try {
        var coverage=RangeAnchors.display(contents,mark,this.state.href,this.state.base);
        if(!coverage.notes.length&&!coverage.highlights.length)return false;
        var css=contents.window.CSS, Highlight=contents.window.Highlight;
        if (!css || !css.highlights || !Highlight) return false;
        var style=contents.document.getElementById('harmony-reader-mark-style');
        if (!style) {
          style=contents.document.createElementNS('http://www.w3.org/1999/xhtml','style');
          style.id='harmony-reader-mark-style';contents.document.head.appendChild(style);
        }
        style.textContent='::highlight('+highlightName+') { background-color: rgba(227, 166, 67, 0.42); }'+
          '::highlight('+noteName+') { text-decoration: underline; text-decoration-thickness: 2px; text-underline-offset: 3px; text-decoration-color: '+(readerSettings.theme==='eye-comfort'?'#b67423':'currentColor')+'; }';
        textMarks.set(mark.markId,{notes:coverage.notes,highlights:coverage.highlights,
          ranges:coverage.notes.concat(coverage.highlights),kind:mark.kind==='note'?'note':'highlight'});
        return refreshTextMarks();
      }catch(_){textMarks.delete(mark.markId);return false;}
    },
    removeTextMark: function (markId) {
      if (typeof markId !== 'string' || !textMarks.delete(markId) || !contents) return false;
      try { return refreshTextMarks(); } catch (_) { return false; }
    },
    textMarkRegistered: function (mark) {
      var registered=textMarks.get(mark.markId);
      return !!contents && !!registered && registered.kind===(mark.kind==='note'?'note':'highlight') &&
        registered.ranges.length>0 &&
        !!contents.window.CSS && !!contents.window.CSS.highlights &&
        contents.window.CSS.highlights.has(mark.kind==='note'?noteName:highlightName) &&
        !!contents.document.getElementById('harmony-reader-mark-style');
    },
    noteAnchorResolutions: function (mark,expectedSession) {
      if(!this.state||this.state.session!==expectedSession||!contents||frame.contentDocument!==firstDocument)return [];
      return RangeAnchors.display(contents,mark,this.state.href,this.state.base).resolutions;
    },
    startLoad: function (packet, id, wide, resourceRoot, token, settings, concealUntilRestored, initialAtEnd, session, mode, presentationToken, surfaceVersion) {
      this.setPaginationMode(mode || 'scroll');
      if (paginationMode === 'clip') closePresentation(presentationToken);
      this.loadDone = false; this.loadResult = null;
      setReaderSettings(settings);
      frame.style.visibility = concealUntilRestored ? 'hidden' : 'visible';
      const task=this.load(packet,id,wide,resourceRoot,initialAtEnd,session,surfaceVersion), epoch=loadEpoch;
      task.then(function (state) { if(epoch===loadEpoch){Surface.loadResult=state; Surface.loadDone=true;ChapterBridge.loadDone(id,token,!!state.complete);} }, function () { if(epoch===loadEpoch){Surface.loadResult={complete:false}; Surface.loadDone=true;ChapterBridge.loadDone(id,token,false);} });
    },
    captureAnchor: function (unit) {
      if (!contents || !this.state) throw new Error('No chapter to anchor');
      if (this.anchor && this.anchorUnit === unit && this.anchorRevision === (this.state.layoutRevision || 0)) return true;
      var left = unit * this.state.viewport, right = left + this.state.viewport;
      var doc = contents.document, walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      var node, range = doc.createRange();
      while ((node = walker.nextNode())) {
        if (!node.data.trim()) continue;
        range.selectNodeContents(node);
        var visible = Array.from(range.getClientRects()).some(function (rect) { return rect.width > 0 && rect.right > left && rect.left < right; });
        if (!visible) continue;
        // LTR text offsets advance monotonically through horizontal columns.
        var low = 0, high = node.length;
        while (low < high) {
          var mid = Math.floor((low + high) / 2);
          range.setStart(node, mid); range.setEnd(node, Math.min(node.length, mid + 1));
          if (range.getBoundingClientRect().right <= left) low = mid + 1; else high = mid;
        }
        if (low >= node.length) continue;
        range.setStart(node, low); range.setEnd(node, Math.min(node.length, low + 1));
        var box = range.getBoundingClientRect();
        if (box.right <= left || box.left >= right) continue;
        this.anchor = contents.cfiFromRange(range);
        this.anchorText = range.toString();
        this.anchorUnit = unit; this.anchorRevision = this.state.layoutRevision || 0;
        return true;
      }
      throw new Error('No visible text anchor');
    },
    beginRelayout: function (width,height,revision) {
      cancelResize(); this.relayoutDone=false; this.relayoutResult=null;
      var check=function(){
        if(Math.abs(innerWidth-width)>2||Math.abs(innerHeight-height)>2)return;
        cancelResize();
        try { Surface.relayoutResult=Surface.relayout(true,revision); }
        catch (_) { Surface.relayoutResult={complete:false}; }
        Surface.relayoutDone=true;
      };
      watchResize(check);
    },
    relayout: function (restoreAnchor, revision) {
      if (!contents || frame.contentDocument !== firstDocument) throw new Error('Chapter identity lost');
      var width = innerWidth, height = innerHeight, geometry = columnGeometry(width);
      contents.document.getSelection().removeAllRanges();
      if (paginationMode === 'clip') { pageOffset = 0; frame.style.transform = 'none'; }
      window.scrollTo(0, 0); frame.style.width = '100%';
      contents.columns(width, height, geometry.width, geometry.gap, 'ltr');
      var units = Math.ceil(contents.textWidth() / width);
      frame.style.width = units * width + 'px';
      var target = 0, anchorMatches = true;
      if (restoreAnchor) {
        var range = contents.range(this.anchor);
        anchorMatches = !!range && range.toString() === this.anchorText;
        if (!anchorMatches) throw new Error('Layout anchor mismatch');
        target = Math.max(0, Math.min(units - 1, Math.floor(range.getBoundingClientRect().left / width)));
      }
      this.state.viewport = width; this.state.height = height; this.state.units = units; this.state.layoutRevision = revision;
      if (restoreAnchor) { this.anchorUnit = target; this.anchorRevision = revision; } else { this.anchor = null; this.anchorUnit = undefined; }
      renderPage(target);
      var actual = this.inspect();
      actual.anchorMatches = anchorMatches;
      actual.anchorVisible = !restoreAnchor || (range.getBoundingClientRect().right > pageLeft() && range.getBoundingClientRect().left < pageLeft() + width);
      return actual;
    },
    applyTheme: function (theme) {
      if (!['light','dark','eye-comfort'].includes(theme)) throw new Error('Invalid reader theme');
      readerSettings.theme=theme;
      applyReaderCanvas();
      var doc=frame.contentDocument;
      if (doc && doc.head) applyReaderTheme(doc);
      return true;
    },
    configure: function (settings, cfi, revision) {
      this.configureFailureCode = 0;
      var phase = 1;
      try {
        setReaderSettings(settings);
        phase = 2;
        if (!contents || !this.state) { this.configureFailureCode = phase; return null; }
        applyReaderStyle(contents.document);
        applyBodyTypography(contents.document);
        phase = 3;
        this.relayout(false,revision);
        phase = 4;
        var unit=typeof cfi==='string' && cfi ? this.unitForCfi(cfi) :
          Math.min(this.state.units-1,Math.max(0,this.state.unit||0));
        if (unit<0) throw new Error('Layout locator failed');
        phase = 5;
        return this.seek(unit);
      } catch (_) {
        this.configureFailureCode = phase;
        throw _;
      }
    },
    beginConfigure: function (settings, cfi, revision, width, height, token, presentationToken, expectedVersion) {
      this.configureFailureCode = 0;
      if (paginationMode === 'clip' && expectedVersion !== undefined &&
        (!this.state || this.state.surfaceVersion !== expectedVersion)) {
        ChapterBridge.layoutDone(slot, token, false); return;
      }
      if (token < latestConfigureToken) {
        ChapterBridge.layoutDone(slot, token, false);
        return;
      }
      latestConfigureToken = token;
      if (paginationMode === 'clip') closePresentation(presentationToken);
      cancelResize(); this.configureResult = null; this.configureResultToken = 0;
      var check = function () {
        if (token !== latestConfigureToken) return;
        if (paginationMode === 'clip' && expectedVersion !== undefined &&
          (!Surface.state || Surface.state.surfaceVersion !== expectedVersion)) {
          cancelResize(); ChapterBridge.layoutDone(slot, token, false); return;
        }
        if (Math.abs(innerWidth - width) > 2 || Math.abs(innerHeight - height) > 2) return;
        cancelResize();
        try { Surface.configureResult = Surface.configure(settings, cfi, revision); }
        catch (_) { Surface.configureResult = { complete: false }; }
        Surface.configureResultToken = token;
        ChapterBridge.layoutDone(slot, token, !!Surface.configureResult && !!Surface.configureResult.complete);
      };
      watchResize(check);
    },
    checkAnchor: function () {
      if (!this.anchor) return false;
      var range = contents.range(this.anchor), box = range.getBoundingClientRect();
      return range.toString() === this.anchorText && box.right > pageLeft() && box.left < pageLeft() + innerWidth;
    },
    releaseChapter: function(){
      this.cancelLoad();
      cancelResize();
      if(removeBridgeListeners){removeBridgeListeners();removeBridgeListeners=null;}
      clearTextMarks();
      if(contents){contents.destroy();contents=null;}
      var doc=frame.contentDocument;
      var empty=new DOMParser().parseFromString('<html xmlns="http://www.w3.org/1999/xhtml"><head/><body/></html>','application/xhtml+xml');
      RangeAnchors.invalidate(doc);
      doc.replaceChild(doc.importNode(empty.documentElement,true),doc.documentElement);
      applyReaderStyle(doc);
      firstDocument=null;this.state=null;this.loadResult=null;this.anchor=null;
      if (paginationMode === 'clip') { pageOffset = 0; frame.style.transform = 'none'; }
      frame.style.width='100%';window.scrollTo(0,0);
    },
    closeSourceForMemory: function(){
      ++sourceEpoch;closeWorker();
      workerStats=null;this.packetResult=null;
      return {workerClosed:!sourceWorker,pending:workerPending.size};
    },
    seek: function (unit, presentationToken, expectedVersion) {
      if (paginationMode === 'clip' && expectedVersion !== undefined &&
        (!this.state || this.state.surfaceVersion !== expectedVersion)) throw new Error('Obsolete surface position');
      if (paginationMode === 'clip' && Number.isSafeInteger(presentationToken) &&
        presentationToken < latestPresentation) throw new Error('Obsolete presentation position');
      if (!this.state || unit < 0 || unit >= this.state.units) throw new Error('Unit outside layout');
      if (paginationMode === 'clip') { this.clearSelection(); closePresentation(presentationToken); }
      renderPage(unit);
      return this.inspect();
    },
    revealRestored: function (unit) {
      var actual = this.inspect();
      if (!actual.complete || actual.unit !== unit) throw new Error('Restored page not ready');
      frame.style.visibility = 'visible';
      return true;
    },
    pageLocator: function (unit) {
      if (!contents || !this.state || !Number.isInteger(unit) || unit < 0 || unit >= this.state.units) return '';
      var left=unit*this.state.viewport, right=left+this.state.viewport;
      var doc=contents.document, walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT), node, range=doc.createRange();
      while((node=walker.nextNode())){
        if(!node.data.trim() || node.parentElement.closest('script,style'))continue;
        range.selectNodeContents(node);
        if(!Array.from(range.getClientRects()).some(rect=>rect.width>0 && rect.right>left && rect.left<right))continue;
        var low=0,high=node.length;
        while(low<high){var mid=Math.floor((low+high)/2);range.setStart(node,mid);range.setEnd(node,Math.min(node.length,mid+1));if(range.getBoundingClientRect().right<=left)low=mid+1;else high=mid;}
        if(low>=node.length)continue;
        for(var offset=low;offset<node.length;offset++){
          range.setStart(node,offset);range.setEnd(node,offset+1);
          var box=range.getBoundingClientRect();
          if(box.left>=right)break;
          if(box.right>left && box.left<right){
            // A collapsed caret at a column boundary may report the previous
            // column. Keep the character range and verify its return page.
            var cfi=contents.cfiFromRange(range);
            if(this.unitForCfi(cfi)===unit)return cfi;
          }
        }
      }
      for(var element of doc.body.querySelectorAll('img,svg')){
        var rect=element.getBoundingClientRect();
        if(rect.width>0 && rect.right>left && rect.left<right){
          var imageCfi=new ePub.CFI(element,this.state.base).toString();
          if(this.unitForCfi(imageCfi)===unit)return imageCfi;
        }
      }
      return unit===0?this.state.originalCfi:'';
    },
    pageExcerpt: function (unit) {
      if (!contents || !this.state || frame.contentDocument !== firstDocument) return '';
      var cfi=this.pageLocator(unit);
      if (!cfi) return '';
      try {
        var range=contents.range(cfi), start=range && range.startContainer;
        if (!start || start.nodeType!==Node.TEXT_NODE) return '';
        var block=start.parentElement.closest('p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,figcaption,dt,dd');
        if (!block) return '';
        var walker=contents.document.createTreeWalker(block,NodeFilter.SHOW_TEXT), node, found=false, text='';
        while((node=walker.nextNode()) && text.length<240){
          if(node===start)found=true;
          if(!found || node.parentElement.closest('script,style'))continue;
          text+=node===start?node.data.slice(range.startOffset):node.data;
          if(/[。！？.!?]/.test(text))break;
        }
        text=text.replace(/\s+/g,' ').trim();
        var sentence=text.match(/^.*?[。！？.!?](?:[”’」』])?/);
        if(sentence)text=sentence[0];
        var points=Array.from(text);
        return points.slice(0,120).join('');
      }catch(_){return '';}
    },
    unitForCfi: function (cfi) {
      if (!contents || !this.state || typeof cfi!=='string' || cfi.length>4096) return -1;
      try {
        var range=contents.range(cfi);if(!range)return -1;
        if(range.collapsed && range.startContainer.nodeType===Node.TEXT_NODE &&
          range.startOffset<range.startContainer.length){
          range.setEnd(range.startContainer,range.startOffset+1);
        }
        var rect=range.getBoundingClientRect();
        return Math.max(0,Math.min(this.state.units-1,Math.floor(rect.left/this.state.viewport)));
      }
      catch(_){return -1;}
    },
    unitForFragment: function (fragment) {
      if (!contents || !this.state || typeof fragment !== 'string' || fragment.length > 256) return -1;
      try {
        var id = decodeURIComponent(fragment.replace(/^#/,''));
        var element = contents.document.getElementById(id);
        if (!element) return -1;
        var rect = element.getBoundingClientRect();
        return Math.max(0,Math.min(this.state.units-1,Math.floor(rect.left/this.state.viewport)));
      } catch (_) { return -1; }
    },
    inspect: function () {
      var last = contents && contents.document.querySelector('p#note');
      var lastRange = last && contents.document.createRange();
      if (lastRange) lastRange.selectNodeContents(last);
      var lastBox = lastRange && lastRange.getBoundingClientRect();
      var box=frame.getBoundingClientRect();
      var valid=paginationMode!=='clip'||(!this.state||Math.abs(scrollX)<=2&&
        Math.abs(frame.contentWindow.scrollX)<=2&&Math.abs(box.left+this.state.unit*this.state.viewport-pageOffset)<=2);
      return Object.assign({}, this.state, { retained: frame.contentDocument === firstDocument, selected: contents ? !contents.document.getSelection().isCollapsed : false,
        scrollX: scrollX, unit: paginationMode==='clip'&&this.state?this.state.unit:Math.round(scrollX / innerWidth), viewport: innerWidth,
        paginationMode:paginationMode,contentOffsetX:box.left,positionValid:valid,
        lastInViewport: !!lastBox && lastBox.left - pageLeft() >= -1 && lastBox.left - pageLeft() < innerWidth,
        lastLeft: lastBox ? lastBox.left : 0, lastRight: lastBox ? lastBox.right : 0,
        notePresent: !!last, noteRects: last ? last.getClientRects().length : 0,
        noteDisplay: last ? contents.window.getComputedStyle(last).display : 'missing',
        liveParagraphs: contents ? contents.document.querySelectorAll('p').length : 0,
        previousLeft: last && last.previousElementSibling ? last.previousElementSibling.getBoundingClientRect().left : 0,
        frameWidth: frame.getBoundingClientRect().width,
        measuredAfter: contents ? contents.textWidth() : 0 });
    }
  };
  addEventListener('resize',function(){
    if(contents && typeof ChapterBridge!=='undefined' && ChapterBridge.viewportChanged){
      ChapterBridge.viewportChanged(slot,innerWidth,innerHeight);
    }
  });
}());
