package funkin.game;

import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.backend.MusicBeatState;
import funkin.backend.chart.ChartData;
import funkin.backend.assets.AssetSource;
import haxe.Timer;
import haxe.io.Path;
import haxe.xml.Access;

using StringTools;

class PlayStateLoadingState extends MusicBeatState {
	public static var lastStartedAt:Float = 0;
	public static var lastFinishedAt:Float = 0;
	public static var lastLoadDurationMs:Float = 0;

	var __skipTransition:Bool;
	var __tasks:Array<PlayStatePreloadTask> = [];
	var __taskIndex:Int = 0;
	var __statusText:FlxText;
	var __currentLabel:String = "Preparing song...";
	var __startedAt:Float = 0;
	var __readyToSwitch:Bool = false;
	var __drewReadyFrame:Bool = false;

	public function new(skipTransition:Bool = true) {
		super(false);
		__skipTransition = skipTransition;
	}

	override public function create() {
		super.create();

		persistentUpdate = true;
		persistentDraw = true;
		bgColor = FlxColor.BLACK;

		__statusText = new FlxText(0, 0, FlxG.width, "");
		__statusText.setFormat(Paths.font(Flags.DEFAULT_FONT), 24, FlxColor.WHITE, CENTER);
		__statusText.screenCenter();
		add(__statusText);

		var song = PlayState.SONG;
		if (song == null)
			song = PlayState.SONG = funkin.backend.chart.Chart.parse("tutorial", PlayState.difficulty, PlayState.variation);

		__startedAt = Timer.stamp();
		lastStartedAt = __startedAt;
		buildTasks(song);
		updateStatus();
	}

	override public function update(elapsed:Float) {
		super.update(elapsed);

		if (__readyToSwitch) {
			if (__drewReadyFrame)
				finishLoading();
			return;
		}

		var tasksPerFrame = #if mobile 2 #else 4 #end;
		while (tasksPerFrame-- > 0 && __taskIndex < __tasks.length) {
			var task = __tasks[__taskIndex++];
			__currentLabel = task.label;
			try {
				task.run();
			} catch (e) {
				Logs.trace('PlayState preload task "${task.label}" failed: ${Std.string(e)}', ERROR);
			}
		}

		if (__taskIndex >= __tasks.length) {
			__readyToSwitch = true;
			__currentLabel = "Entering song...";
		}

		updateStatus();
	}

	override public function draw() {
		super.draw();
		if (__readyToSwitch)
			__drewReadyFrame = true;
	}

	function finishLoading() {
		lastFinishedAt = Timer.stamp();
		lastLoadDurationMs = (lastFinishedAt - __startedAt) * 1000;

		Logs.infos('PlayStateLoadingState finished in ${Std.int(lastLoadDurationMs)}ms for ${PlayState.SONG != null ? PlayState.SONG.meta.name : "unknown"}', "PlayState");

		Paths.preserveTempFramesForNextStateSwitch();
		if (__skipTransition) {
			MusicBeatState.skipTransIn = true;
			MusicBeatState.skipTransOut = true;
		}
		FlxG.switchState(new PlayState());
	}

	function updateStatus() {
		var total = __tasks.length <= 0 ? 1 : __tasks.length;
		var current = __taskIndex > total ? total : __taskIndex;
		__statusText.text = 'Loading ${PlayState.SONG != null ? PlayState.SONG.meta.displayName.getDefault(PlayState.SONG.meta.name) : "song"}\n$current/$total\n$__currentLabel';
		__statusText.screenCenter();
	}

	function buildTasks(song:ChartData) {
		queueStagePreload(song);
		queueSongScriptPreload(song);
		queueCharacterPreload(song);
		queueGameplayAssetPreload(song);
		queueAudioPreload(song);
	}

	inline function queueTask(label:String, run:Void->Void) {
		__tasks.push({label: label, run: run});
	}

	function queueStagePreload(song:ChartData) {
		var stageName = song.stage;
		if (stageName == null || stageName.trim() == "")
			stageName = Flags.DEFAULT_STAGE;

		var stagePath = Paths.xml('stages/$stageName');
		var stageXML = readXML(stagePath);
		if (stageXML == null)
			return;

		queueTask('Stage XML $stageName', function() preloadTextAsset(stagePath));

		var stageScriptPath = Paths.script('data/stages/$stageName');
		queueTask('Stage script $stageName', function() preloadTextAsset(stageScriptPath));
		queueImportedScriptsFromXML(stageXML, 'Stage');

		var parentFolder = stageXML.getAtt("folder").getDefault("");
		if (parentFolder != "" && !parentFolder.endsWith("/"))
			parentFolder += "/";

		for (node in getStageNodes(stageXML)) {
			switch (node.name) {
				case "sprite" | "spr" | "sparrow":
					var spriteName = node.getAtt("sprite").getDefault(node.getAtt("name"));
					if (spriteName == null || spriteName == "")
						continue;
					var spriteKey = '$parentFolder$spriteName';
					var spriteLabel = spriteKey;
					queueTask('Stage sprite $spriteLabel', function() preloadSpriteKey(spriteKey));
				default:
			}
		}
	}

	function queueSongScriptPreload(song:ChartData) {
		var source = PlayState.fromMods ? MODS : BOTH;
		var sharedScriptPath = Paths.script('songs/PlayScripts');
		if (Assets.exists(sharedScriptPath))
			queueTask('Script songs/PlayScripts', function() preloadTextAsset(sharedScriptPath));

		var baseFolder = 'songs/${song.meta.name}/scripts';
		for (folder in [baseFolder, '$baseFolder/${PlayState.difficulty}', 'data/charts', 'songs']) {
			for (file in Paths.getFolderContent(folder, true, source)) {
				var scriptPath = Paths.getPath(file);
				var fileLabel = file;
				queueTask('Script $fileLabel', function() preloadTextAsset(scriptPath));
			}
		}

		var songEvents:Array<String> = [];
		for (event in song.events)
			songEvents.pushOnce(event.name);

		for (eventName in songEvents) {
			var eventScriptPath = Paths.script('data/events/$eventName');
			if (!Assets.exists(eventScriptPath))
				continue;

			var label = 'Event $eventName';
			queueTask(label, function() preloadTextAsset(eventScriptPath));
		}

		for (cutsceneName in ['songs/${song.meta.name}/cutscene', 'songs/${song.meta.name}/cutscene-end']) {
			var cutsceneScriptPath = Paths.script(cutsceneName);
			if (!Assets.exists(cutsceneScriptPath))
				continue;

			var label = cutsceneName;
			queueTask('Cutscene $label', function() preloadTextAsset(cutsceneScriptPath));
		}
	}

	function queueCharacterPreload(song:ChartData) {
		var queuedCharacters:Array<String> = [];
		for (strumLine in song.strumLines) {
			if (strumLine == null || strumLine.characters == null)
				continue;

			for (charName in strumLine.characters) {
				if (charName == null || queuedCharacters.contains(charName))
					continue;
				queuedCharacters.push(charName);

				var xml = Character.getXMLFromCharName(charName);
				if (xml == null)
					continue;

				var characterXMLPath = Paths.xml('characters/$charName');
				queueTask('Character XML $charName', function() preloadTextAsset(characterXMLPath));

				var characterScriptPath = Paths.script(Path.withoutExtension(characterXMLPath), null, true);
				queueTask('Character script $charName', function() preloadTextAsset(characterScriptPath));
				queueImportedScriptsFromXML(xml, 'Character $charName');

				var spriteName = xml.x.exists("sprite") ? xml.x.get("sprite") : charName;
				var spriteLabel = spriteName;
				queueTask('Character sprite $spriteLabel', function() preloadSpriteKey('characters/$spriteName'));

				var iconName = xml.x.exists("icon") ? xml.x.get("icon") : charName;
				var iconLabel = iconName;
				queueTask('Icon $iconLabel', function() preloadHealthIcon(iconName));
			}
		}
	}

	function queueGameplayAssetPreload(song:ChartData) {
		var maxKeyCount = getMaxKeyCount(song);
		queueTask('Default note frames', function() preloadNoteSprite('game/notes/default', maxKeyCount));

		var queuedNoteTypes:Array<String> = [];
		for (noteType in song.noteTypes) {
			if (noteType == null || noteType == "" || queuedNoteTypes.contains(noteType))
				continue;
			queuedNoteTypes.push(noteType);

			var noteSpriteKey = 'game/notes/$noteType';
			var spriteLabel = noteType;
			queueTask('Note type $spriteLabel', function() {
				if (Paths.framesExists(noteSpriteKey))
					preloadNoteType(noteType, maxKeyCount);
			});

			var noteScriptPath = Paths.script('data/notes/$noteType');
			queueTask('Note script $spriteLabel', function() preloadTextAsset(noteScriptPath));
		}

		for (content in Paths.getFolderContent('images/game/score/', true, BOTH)) {
			var path = Paths.getPath(content);
			var label = content;
			queueTask('Score sprite $label', function() preloadGraphicPath(path));
		}

		queueTask('Health bar', function() preloadGraphicPath(Paths.image('game/healthBar')));

		for (sprite in Flags.DEFAULT_INTRO_SPRITES) {
			if (sprite == null)
				continue;
			var spriteLabel = sprite;
			queueTask('Intro sprite $spriteLabel', function() preloadGraphicPath(Paths.image(sprite)));
		}

		for (sound in Flags.DEFAULT_INTRO_SOUNDS) {
			if (sound == null)
				continue;
			var soundLabel = sound;
			queueTask('Intro sound $soundLabel', function() preloadSoundPath(Paths.sound(sound), false));
		}

		for (sound in Flags.DEFAULT_MISS_SOUNDS) {
			var soundLabel = sound;
			queueTask('Miss sound $soundLabel', function() preloadSoundPath(Paths.sound(sound), false));
		}

		for (file in Paths.getFolderContent('data/splashes/', true, BOTH)) {
			if (Path.extension(file).toLowerCase() != "xml")
				continue;

			var splashPath = Paths.getPath(file);
			var splashXML = readXML(splashPath);
			if (splashXML == null)
				continue;

			var splashLabel = Path.withoutExtension(file);
			queueTask('Splash XML $splashLabel', function() preloadTextAsset(splashPath));
			if (splashXML.has.sprite) {
				var splashSprite = splashXML.att.sprite;
				var spriteLabel = splashSprite;
				queueTask('Splash sprite $spriteLabel', function() preloadSpriteKey(splashSprite));
			}
		}
	}

	function queueAudioPreload(song:ChartData) {
		var instPath = Paths.inst(song.meta.name, PlayState.difficulty, song.meta.instSuffix);
		queueTask('Inst', function() preloadMusicPath(instPath));

		var vocalsPath = Paths.voices(song.meta.name, PlayState.difficulty, song.meta.vocalsSuffix);
		if (song.meta.needsVoices && Assets.exists(vocalsPath))
			queueTask('Vocals', function() preloadSoundPath(vocalsPath, Options.streamedVocals));

		var queuedSuffixes:Array<String> = [];
		for (strumLine in song.strumLines) {
			if (strumLine == null)
				continue;

			var suffix = strumLine.vocalsSuffix;
			if (suffix == null || suffix == "" || queuedSuffixes.contains(suffix))
				continue;
			queuedSuffixes.push(suffix);

			var extraVocalsPath = Paths.voices(song.meta.name, PlayState.difficulty, suffix);
			if (!Assets.exists(extraVocalsPath))
				continue;

			var label = suffix;
			queueTask('Extra vocals $label', function() preloadSoundPath(extraVocalsPath, Options.streamedVocals));
		}
	}

	function queueImportedScriptsFromXML(xml:Access, labelPrefix:String) {
		for (node in xml.elements) {
			switch (node.name) {
				case "use-extension" | "extension" | "ext":
					if (!node.has.script)
						continue;

					var folder = node.getAtt("folder").getDefault("data/scripts/");
					if (!folder.endsWith("/"))
						folder += "/";

					var scriptName = node.getAtt("script");
					var scriptPath = Paths.script(folder + scriptName);
					var label = '$labelPrefix extension $scriptName';
					queueTask(label, function() preloadTextAsset(scriptPath));
				default:
			}
		}
	}

	function getStageNodes(stageXML:Access):Array<Access> {
		var elems:Array<Access> = [];
		for (node in stageXML.elements) {
			if (node.name == "high-memory" && !Options.lowMemoryMode) {
				for (child in node.elements)
					elems.push(child);
			} else if (node.name == "low-memory" && Options.lowMemoryMode) {
				for (child in node.elements)
					elems.push(child);
			} else if (node.name != "high-memory" && node.name != "low-memory") {
				elems.push(node);
			}
		}
		return elems;
	}

	function preloadTextAsset(path:String) {
		if (path != null && Assets.exists(path))
			Assets.getText(path);
	}

	function preloadMusicPath(path:String) {
		if (path != null && Assets.exists(path))
			Assets.getMusic(path);
	}

	function preloadSoundPath(path:String, streamed:Bool) {
		if (path == null || !Assets.exists(path))
			return;
		if (streamed)
			Assets.getMusic(path);
		else
			Assets.getSound(path);
	}

	function preloadHealthIcon(icon:String) {
		var oldIconPath = 'icons/$icon';
		var newIconPath = 'icons/$icon/icon';
		if (Assets.exists(Paths.image(oldIconPath)))
			preloadGraphicPath(Paths.image(oldIconPath));
		if (Paths.framesExists(Paths.image(newIconPath), true, true, true))
			preloadFramesPath(Paths.image(newIconPath, null, true));

		var iconXmlPath = Paths.getPath('images/icons/$icon/data.xml');
		preloadTextAsset(iconXmlPath);
	}

	function preloadGraphicPath(path:String) {
		if (path != null && Assets.exists(path))
			graphicCache.cache(path);
	}

	function preloadSpriteKey(key:String) {
		preloadFramesPath(Paths.image(key, null, true));
	}

	function preloadNoteType(noteType:String, keyCount:Int) {
		var noteSprite = Note.preloadNoteType(noteType, keyCount);
		preloadFramesKey(noteSprite);
	}

	function preloadNoteSprite(noteSprite:String, keyCount:Int) {
		Note.preloadNoteSprite(noteSprite, keyCount);
		preloadFramesKey(noteSprite);
	}

	function preloadFramesKey(key:String) {
		var frames = Paths.getFrames(key);
		if (frames != null && frames.parent != null)
			graphicCache.cacheGraphic(frames.parent);
	}

	function preloadFramesPath(path:String) {
		if (path == null)
			return;

		var frames = Paths.getFrames(path, true);
		if (frames != null && frames.parent != null)
			graphicCache.cacheGraphic(frames.parent);
		else if (Assets.exists(path))
			graphicCache.cache(path);
	}

	function readXML(path:String):Access {
		if (path == null || !Assets.exists(path))
			return null;

		try {
			return new Access(Xml.parse(Assets.getText(path)).firstElement());
		} catch (e) {
			Logs.trace('Failed to parse preload XML at $path: ${Std.string(e)}', ERROR);
		}
		return null;
	}

	function getMaxKeyCount(song:ChartData):Int {
		var maxKeyCount = Flags.DEFAULT_STRUM_AMOUNT;
		if (song != null && song.strumLines != null) {
			for (strumLine in song.strumLines) {
				if (strumLine != null && strumLine.keyCount != null && strumLine.keyCount > maxKeyCount)
					maxKeyCount = strumLine.keyCount;
			}
		}
		return maxKeyCount;
	}
}

private typedef PlayStatePreloadTask = {
	var label:String;
	var run:Void->Void;
}
