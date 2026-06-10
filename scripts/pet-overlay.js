#!/usr/bin/env osascript -l JavaScript
// claude-pokemon-pet overlay: a borderless, click-through, always-on-top
// window with an animated Pokémon that reacts to Claude Code session state
// (written by pet-state.sh hooks). A new random gen-1 Pokémon is rolled each
// day; it levels with completed tasks and evolves along its chain.
// ⌥-drag to move. Usage: pet-overlay.js <plugin-root>

ObjC.import('Cocoa');
ObjC.import('QuartzCore');

function run(argv) {
  var HOME = ObjC.unwrap($.NSHomeDirectory());
  var ROOT = (argv && argv[0]) || HOME + '/.claude/pokemon-pet';
  var CACHE = HOME + '/.cache/claude-pet';
  var SPRITES = CACHE + '/sprites-big';
  var POSF = CACHE + '/pos';
  var EVO2 = 6, EVO3 = 16;       // tasks/day needed for stage 2 / 3
  var BOTTOM_OFFSET = 30;        // default home: just above the tmux bar
  var ROAM = 240;                // wander range while working (px)

  var TYPE_MOVES = {
    normal:   ['TACKLE', 'BODY SLAM', 'HYPER BEAM'],
    fire:     ['EMBER', 'FLAMETHROWER', 'FIRE BLAST'],
    water:    ['WATER GUN', 'SURF', 'HYDRO PUMP'],
    grass:    ['VINE WHIP', 'RAZOR LEAF', 'SOLAR BEAM'],
    electric: ['THUNDER SHOCK', 'THUNDERBOLT', 'THUNDER'],
    psychic:  ['CONFUSION', 'PSYBEAM', 'PSYCHIC'],
    fighting: ['KARATE CHOP', 'SEISMIC TOSS', 'SUBMISSION'],
    rock:     ['ROCK THROW', 'ROCK SLIDE', 'EARTHQUAKE'],
    ground:   ['DIG', 'BONE CLUB', 'EARTHQUAKE'],
    poison:   ['POISON STING', 'ACID', 'SLUDGE'],
    bug:      ['LEECH LIFE', 'PIN MISSILE', 'TWINEEDLE'],
    flying:   ['GUST', 'WING ATTACK', 'DRILL PECK'],
    ghost:    ['LICK', 'NIGHT SHADE', 'DREAM EATER'],
    ice:      ['AURORA BEAM', 'ICE BEAM', 'BLIZZARD'],
    dragon:   ['DRAGON RAGE', 'SLAM', 'HYPER BEAM']
  };

  function readFile(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null);
    return (!s || s.isNil()) ? '' : ObjC.unwrap(s).trim();
  }
  function writeFile(p, text) {
    $(text).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, null);
  }
  function today() {
    var d = new Date();
    return d.getFullYear() + '-' +
      ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
  }

  var chains = JSON.parse(readFile(ROOT + '/data/chains.json'));

  // The partner never changes mid-run; the daily gacha roll happens in the
  // CLI when the overlay starts (claude-pet start/autostart).
  function currentChain() {
    var idx = parseInt(readFile(CACHE + '/pet'), 10);
    if (isNaN(idx) || idx < 0 || idx >= chains.length) idx = 1; // charmander
    return chains[idx];
  }

  function petState() {
    var chain = currentChain();
    var tasks = 0;
    var t = readFile(CACHE + '/tasks').split(/\s+/);
    if (t.length === 2 && t[0] === today()) tasks = parseInt(t[1], 10) || 0;

    var stage = Math.min(1 + (tasks >= EVO2 ? 1 : 0) + (tasks >= EVO3 ? 1 : 0), chain.mons.length);

    var st = readFile(CACHE + '/state').split(/\s+/);
    var state = st[0] || 'idle';
    var age = Math.floor(Date.now() / 1000) - (parseInt(st[1], 10) || 0);
    if ((state === 'done' || state === 'hello') && age > 45) state = 'idle';
    if ((state === 'thinking' || state === 'working' || state === 'waiting') && age > 600) state = 'idle';

    return {
      mons: chain.mons, type: chain.type, mon: chain.mons[stage - 1],
      stage: stage, final: stage === chain.mons.length,
      state: state, age: age, tasks: tasks
    };
  }

  // Battle-log captions; rotates every 7s within a state
  function pick(arr) { return arr[Math.floor(Date.now() / 7000) % arr.length]; }
  function moodText(p) {
    var N = p.mon.toUpperCase();
    switch (p.state) {
      case 'thinking': return pick([N + ' is getting pumped!', N + ' is sizing up the task!']);
      case 'working':  return N + ' used ' + pick(TYPE_MOVES[p.type] || TYPE_MOVES.normal) + '!';
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
  var nameLabel = makeLabel(30, 12, true, 0.95, 0.78, 0.45, 0.95);
  var moodLabel = makeLabel(6, 10, false, 0.80, 0.84, 0.98, 0.92);
  win.contentView.addSubview(nameLabel);
  win.contentView.addSubview(moodLabel);

  // EXP bar: progress to next evolution
  var EXPW = 110, EXPH = 4, expX = (winW - EXPW) / 2, expY = 25;
  function cg(r, g, b, a) { return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a).CGColor; }
  var expTrack = $.CAShapeLayer.layer;
  expTrack.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(expX, expY, EXPW, EXPH), 2, 2, null));
  expTrack.setFillColor(cg(0.28, 0.30, 0.42, 0.85));
  win.contentView.layer.addSublayer(expTrack);
  var expFill = $.CAShapeLayer.layer;
  expFill.setFillColor(cg(0.49, 0.81, 1.0, 0.95));
  win.contentView.layer.addSublayer(expFill);
  function setExp(p) {
    var frac = p.final ? 1 :
      p.stage === 2 ? (p.tasks - EVO2) / (EVO3 - EVO2) : p.tasks / EVO2;
    frac = Math.max(0.02, Math.min(1, frac));
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
  var evolveUntil = 0, evolveName = '', prevStage = 0;
  function refresh() {
    var p = petState();
    current.state = p.state;
    current.age = p.age;
    current.mon = p.mon;
    if (prevStage && p.stage > prevStage) {
      evolveUntil = Date.now() + 10000;
      evolveName = p.mons[prevStage - 1].toUpperCase();
    }
    prevStage = p.stage;
    setSprite(p.mon, p.state === 'working' ? facing : 'l');
    nameLabel.setStringValue($(p.mon.toUpperCase() + '  Lv.' + p.tasks));
    moodLabel.setStringValue($(Date.now() < evolveUntil
      ? 'What? ' + evolveName + ' is evolving!' : moodText(p)));
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
