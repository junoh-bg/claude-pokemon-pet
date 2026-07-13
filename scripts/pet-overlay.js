#!/usr/bin/env osascript -l JavaScript
// claude-pokemon-pet overlay: a borderless, click-through, always-on-top
// window with an animated Pokémon that reacts to Claude Code session state.
// A pure view: all game state (species, level, EXP, localized names/moves)
// comes from resolved.json, written by pet-core.sh. The overlay keeps only
// presentation logic: animation, mood decay by age, evolution cutscene.
// ⌥-drag to move. Usage: pet-overlay.js <plugin-root>

ObjC.import('Cocoa');
ObjC.import('QuartzCore');

function run(argv) {
  var HOME = ObjC.unwrap($.NSHomeDirectory());
  var CACHE = HOME + '/.cache/claude-pokemon-pet';
  var SPRITES = CACHE + '/sprites-big';
  var POSF = CACHE + '/pos';
  var BOTTOM_OFFSET = 30;        // default home: just above the tmux bar
  var ROAM = 240;                // wander range while working (px)

  function readFile(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null);
    return (!s || s.isNil()) ? '' : ObjC.unwrap(s).trim();
  }
  function writeFile(p, text) {
    $(text).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, null);
  }
  function josa(w, withFinal, noFinal) { // e.g. josa(name, '은', '는')
    var c = w.charCodeAt(w.length - 1);
    var hasFinal = c >= 0xAC00 && c <= 0xD7A3 && (c - 0xAC00) % 28 > 0;
    return w + (hasFinal ? withFinal : noFinal);
  }

  // Pure view of resolved.json (written by pet-core.sh). The only session
  // logic kept here is presentation: mood decay by age of the last event.
  function petState() {
    var r;
    try { r = JSON.parse(readFile(CACHE + '/resolved.json')); } catch (e) { return null; }
    if (!r || !r.species) return null;
    var age = Math.floor(Date.now() / 1000) - (r.state_ts || 0);
    var state = r.state || 'idle';
    if ((state === 'done' || state === 'hello') && age > 45) state = 'idle';
    if ((state === 'thinking' || state === 'working' || state === 'waiting') && age > 600) state = 'idle';
    r.state = state;
    r.age = age;
    return r;
  }

  // Battle-log captions; rotates every 7s within a state. Templates are
  // presentation; p.name and p.moves arrive already localized from the core.
  function pick(arr) { return arr[Math.floor(Date.now() / 7000) % arr.length]; }
  function moodText(p) {
    var move = pick(p.moves && p.moves.length ? p.moves : ['TACKLE']);
    var N = p.name;
    if (p.lang === 'ko') {
      switch (p.state) {
        case 'thinking': return pick([josa(N, '은', '는') + ' 기합을 넣고 있다!', josa(N, '은', '는') + ' 상황을 살피고 있다!']);
        case 'working':  return N + '의 ' + move + '!';
        case 'done':     return pick(['효과는 굉장했다!', josa(N, '은', '는') + ' 경험치를 얻었다!']);
        case 'waiting':  return josa(N, '은', '는') + ' 지시를 기다리고 있다';
        case 'hello':    return '가라! ' + N + '!';
        default:         return josa(N, '은', '는') + ' 쿨쿨 잠들어 있다';
      }
    }
    switch (p.state) {
      case 'thinking': return pick([N + ' is getting pumped!', N + ' is sizing up the task!']);
      case 'working':  return N + ' used ' + move + '!';
      case 'done':     return pick(["It's super effective!", N + ' gained EXP. Points!']);
      case 'waiting':  return N + ' looks at you expectantly';
      case 'hello':    return 'Go! ' + N + '!';
      default:         return N + ' is fast asleep';
    }
  }

  // ── Window ──
  $.NSApplication.sharedApplication;
  $.NSApp.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var winW = 224, winH = 250;
  var mouse = $.NSEvent.mouseLocation;
  var screens = $.NSScreen.screens;
  var screen = screens.objectAtIndex(0);
  for (var s = 0; s < screens.count; s++) {
    var scr = screens.objectAtIndex(s), sf = scr.frame;
    if (mouse.x >= sf.origin.x && mouse.x <= sf.origin.x + sf.size.width &&
        mouse.y >= sf.origin.y && mouse.y <= sf.origin.y + sf.size.height) { screen = scr; break; }
  }
  var vf = screen.visibleFrame;
  var homeX = vf.origin.x + vf.size.width - winW - 24;
  var homeY = vf.origin.y + BOTTOM_OFFSET;

  // Restore a dragged position if it is still on some screen
  var saved = readFile(POSF).split(/\s+/);
  if (saved.length === 2) {
    var sx = parseFloat(saved[0]), sy = parseFloat(saved[1]);
    for (var v = 0; v < screens.count; v++) {
      var sfr = screens.objectAtIndex(v).frame;
      if (!isNaN(sx) && !isNaN(sy) &&
          sx >= sfr.origin.x - winW && sx <= sfr.origin.x + sfr.size.width &&
          sy >= sfr.origin.y - 40 && sy <= sfr.origin.y + sfr.size.height) {
        homeX = sx; homeY = sy; break;
      }
    }
  }

  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(homeX, homeY, winW, winH),
    $.NSWindowStyleMaskBorderless, $.NSBackingStoreBuffered, false
  );
  win.setBackgroundColor($.NSColor.clearColor);
  win.setOpaque(false);
  win.setHasShadow(false);
  win.setLevel($.NSStatusWindowLevel);
  win.setCollectionBehavior($.NSWindowCollectionBehaviorCanJoinAllSpaces | $.NSWindowCollectionBehaviorStationary);
  win.setIgnoresMouseEvents(true);
  win.contentView.wantsLayer = true;

  var imageView = $.NSImageView.alloc.initWithFrame($.NSMakeRect(12, 48, winW - 24, 190));
  imageView.setImageScaling(3); // proportionally up or down
  imageView.setAnimates(true);
  imageView.setWantsLayer(true);
  imageView.layer.setMagnificationFilter($('nearest'));
  win.contentView.addSubview(imageView);

  function makeLabel(yPos, fontSize, bold, r, g, b, a) {
    var font = $.NSFont.fontWithNameSize(bold ? 'Menlo-Bold' : 'Menlo-Regular', fontSize);
    if (!font || font.isNil()) font = $.NSFont.systemFontOfSize(fontSize);
    var label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(4, yPos, winW - 8, 18));
    label.setBezeled(false); label.setDrawsBackground(false);
    label.setEditable(false); label.setSelectable(false);
    label.setAlignment(2);
    label.setFont(font);
    label.setTextColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a));
    var shadow = $.NSShadow.alloc.init;
    shadow.setShadowColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.85));
    shadow.setShadowBlurRadius(3);
    shadow.setShadowOffset($.NSMakeSize(0, -1));
    label.setShadow(shadow);
    return label;
  }

  function cg(r, g, b, a) { return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a).CGColor; }

  // Dark translucent pill behind the caption block so the light text stays
  // readable over any background (the pet floats over white apps too).
  var pill = $.CAShapeLayer.layer;
  pill.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(16, 2, winW - 32, 48), 12, 12, null));
  pill.setFillColor(cg(0.07, 0.08, 0.12, 0.62));
  win.contentView.layer.addSublayer(pill);

  var nameLabel = makeLabel(30, 12, true, 0.95, 0.78, 0.45, 0.95);
  var moodLabel = makeLabel(6, 10, false, 0.86, 0.89, 1.0, 0.95);
  win.contentView.addSubview(nameLabel);
  win.contentView.addSubview(moodLabel);

  // setAlignment proved unreliable here — center deterministically by
  // sizing the label to its text and placing the frame at the midpoint.
  function centerLabel(label) {
    label.sizeToFit;
    var f = label.frame;
    label.setFrameOrigin($.NSMakePoint((winW - f.size.width) / 2, f.origin.y));
  }

  // EXP bar: progress to next evolution
  var EXPW = 110, EXPH = 4, expX = (winW - EXPW) / 2, expY = 25;
  var expTrack = $.CAShapeLayer.layer;
  expTrack.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(expX, expY, EXPW, EXPH), 2, 2, null));
  expTrack.setFillColor(cg(0.50, 0.53, 0.68, 0.95)); // light enough to read on the dark pill
  win.contentView.layer.addSublayer(expTrack);
  var expFill = $.CAShapeLayer.layer;
  expFill.setFillColor(cg(0.49, 0.81, 1.0, 0.95));
  win.contentView.layer.addSublayer(expFill);
  function setExp(p) {
    var frac = Math.max(0.02, Math.min(1, (p.exp_pct || 0) / 100));
    expFill.setFillColor(p.exp_gold ? cg(1.0, 0.82, 0.25, 0.95) : cg(0.49, 0.81, 1.0, 0.95));
    expFill.setPath($.CGPathCreateWithRoundedRect(
      $.CGRectMake(expX, expY, EXPW * frac, EXPH), 2, 2, null));
  }

  // ── State refresh (1s) ──
  var current = { key: '', state: 'idle', age: 9999, mon: '' };
  var facing = 'l';
  function setSprite(mon, dir) {
    var key = mon + '|' + dir;
    if (key === current.key) return;
    var img = $.NSImage.alloc.initWithContentsOfFile(
      $(SPRITES + '/' + mon + (dir === 'r' ? '-flip' : '') + '.gif'));
    if (img && !img.isNil()) { imageView.setImage(img); current.key = key; }
  }
  var evolveUntil = 0, evolveName = '', prevStage = 0, prevName = '';
  function refresh() {
    var p = petState();
    if (!p) return;                        // core hasn't resolved yet
    current.state = p.state;
    current.age = p.age;
    current.mon = p.species;
    if (prevStage && p.stage > prevStage) {
      evolveUntil = Date.now() + 10000;
      evolveName = prevName;
    }
    prevStage = p.stage;
    prevName = p.name;
    setSprite(p.species, p.state === 'working' ? facing : 'l');
    nameLabel.setStringValue($(p.name + '  Lv.' + p.tasks));
    var evolveMsg = p.lang === 'ko'
      ? '어라…!? ' + evolveName + '의 모습이…!'
      : 'What? ' + evolveName + ' is evolving!';
    moodLabel.setStringValue($(Date.now() < evolveUntil ? evolveMsg : moodText(p)));
    centerLabel(nameLabel);
    centerLabel(moodLabel);
    setExp(p);
    win.setAlphaValue(p.state === 'idle' ? 0.55 : 1.0);
  }

  // ── Motion engine (20fps) + manual ⌥-drag ──
  var t = 0, DT = 0.05, lastDx = 0;
  var OPT = 0x80000;
  var dragging = false, grabX = 0, grabY = 0;
  function endDrag() {
    dragging = false;
    homeX = win.frame.origin.x;
    homeY = win.frame.origin.y;
    writeFile(POSF, homeX + ' ' + homeY);
    t = Math.PI / 1.1; // roam phase where dx≈0, so no jump on release
  }
  function move() {
    // ⌥ over the pet: swallow clicks and follow the mouse while pressed.
    var optHeld = ($.CGEventSourceFlagsState(0) & OPT) !== 0;
    var loc = $.NSEvent.mouseLocation;
    var fr = win.frame;
    var inside = loc.x >= fr.origin.x && loc.x <= fr.origin.x + fr.size.width &&
                 loc.y >= fr.origin.y && loc.y <= fr.origin.y + fr.size.height;
    if (optHeld && (inside || dragging)) {
      win.setIgnoresMouseEvents(false);
      if (($.NSEvent.pressedMouseButtons & 1) !== 0) {
        if (!dragging) { dragging = true; grabX = loc.x - fr.origin.x; grabY = loc.y - fr.origin.y; }
        win.setFrameOrigin($.NSMakePoint(loc.x - grabX, loc.y - grabY));
      } else if (dragging) {
        endDrag();
      }
      return;
    }
    win.setIgnoresMouseEvents(true);
    if (dragging) endDrag();

    t += DT;
    var dx = 0, dy = 0;
    switch (current.state) {
      case 'working':
        dx = -ROAM / 2 + (ROAM / 2) * Math.sin(t * 0.55);
        dy = Math.abs(Math.sin(t * 4.0)) * 4;
        var dir = dx >= lastDx ? 'r' : 'l';
        if (dir !== facing) { facing = dir; setSprite(current.mon, facing); }
        lastDx = dx;
        break;
      case 'thinking':
        dy = 5 + 5 * Math.sin(t * 1.6);
        break;
      case 'waiting':
        dx = 4 * Math.sin(t * 7.0);
        break;
      case 'done':
      case 'hello':
        dy = Math.abs(Math.sin(t * 5.0)) * Math.max(0, 22 - current.age * 4);
        break;
      default:
        dy = 1.5 * Math.sin(t * 0.7);
    }
    win.setFrameOrigin($.NSMakePoint(homeX + dx, homeY + dy));
  }

  ObjC.registerSubclass({
    name: 'PetTicker', superclass: 'NSObject',
    methods: {
      'tick:': { types: ['void', ['id']], implementation: function() { refresh(); } },
      'move:': { types: ['void', ['id']], implementation: function() { move(); } }
    }
  });
  var ticker = $.PetTicker.alloc.init;
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(1.0, ticker, 'tick:', null, true);
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(DT, ticker, 'move:', null, true);

  refresh();
  win.orderFrontRegardless;
  $.NSApp.run;
}
