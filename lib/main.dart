import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

ArgResults argResults;

const GRADLE_INDENT = 4;

void main(List<String> arguments) {
  final argParser = ArgParser()..addOption('path', abbr: 'p', defaultsTo: '.');

  argResults = argParser.parse(arguments);

  final String path = argResults['path'];

  var pubspec = getPubspec(path);
  var hasFirebase = pubspec.dependencies.entries
      .where((element) => element.toString().contains('firebase'))
      .isNotEmpty;
  var hasFirebaseMessages = pubspec.dependencies.entries
      .where((element) => element.toString().contains('firebase_messaging'))
      .isNotEmpty;

  getRootGradleContent(path, hasFirebase, hasFirebaseMessages);
  getAppGradleContent(path, hasFirebase, hasFirebaseMessages);
  getManifestContent(path, hasFirebaseMessages);
}

XmlDocument buildIntentXML() {
  final builder = XmlBuilder();
  builder.element('intent-filter', nest: () {
    builder.element('action', nest: () {
      builder.attribute('android:name', 'FLUTTER_NOTIFICATION_CLICK');
    });
    builder.element('category', nest: () {
      builder.attribute('android:name', 'android.intent.category.DEFAULT');
    });
  });
  return builder.buildDocument();
}

void getManifestContent(String path, bool hasFirebaseMessages) {
  var manifest = getManifest(path);
  var content = manifest.readAsStringSync();
  final document = XmlDocument.parse(content);
  var hasNotification = document
      .findAllElements('action')
      .where((element) => element.attributes
          .where((attr) => attr.value == 'FLUTTER_NOTIFICATION_CLICK')
          .isNotEmpty)
      .isNotEmpty;

  if (!hasNotification && hasFirebaseMessages) {
    document
        .findAllElements('manifest')
        .first
        .findAllElements('application')
        .first
        .findAllElements('activity')
        .first
        .children
        .add(buildIntentXML().firstChild.copy());
  }
  var xmlString = document.toXmlString(
    pretty: true,
    indent: '    ',
    indentAttribute: (node) {
      var length = node.parent.attributes.length;
      return !node.name.toString().contains('xmlns') && length > 1;
    },
  );

  manifest.writeAsString(xmlString);
}

void getRootGradleContent(
  String path,
  bool hasFirebase,
  bool hasFirebaseMessages,
) {
  var rootGradle = getRootGradle(path);
  var lines = rootGradle.readAsLinesSync();
  var inBuildscript = false;
  var inDeps = false;
  var hasGMSServies = false;

  var newLines = [];

  for (var line in lines) {
    if (line.contains('buildscript {')) {
      inBuildscript = true;
    }
    if (inBuildscript && line.contains('dependencies {')) {
      inDeps = true;
    }
    if (inBuildscript &&
        inDeps &&
        line.contains('com.google.gms:google-services')) {
      hasGMSServies = true;
    }
    // print('inBuild $inBuildscript, inDeps $inDeps');

    if (hasFirebase && !hasGMSServies) {
      if (inBuildscript && inDeps && line.contains('}')) {
        var re = RegExp(r'(\s)', caseSensitive: false);
        var tabs = re.allMatches(line);

        var spacer = ' ' * (tabs.isNotEmpty ? tabs.length * 2 : GRADLE_INDENT);

        newLines
            .add("${spacer}classpath 'com.google.gms:google-services:4.3.2'");
        inDeps = false;
      }
    }
    newLines.add(line);
  }
  rootGradle.writeAsStringSync(newLines.join('\n'));
}

void getAppGradleContent(
  String path,
  bool hasFirebase,
  bool hasFirebaseMessages,
) {
  var appGradle = getAppGradle(path);
  var lines = appGradle.readAsLinesSync();

  var inDeps = false;
  var inAndroid = false;
  var inConfig = false;
  var hasMessaging = false;
  var hasMultidex = false;
  var hasGMSServices = false;
  var hasSubprojects = false;
  var newLines = [];

  for (var line in lines) {
    if (line.contains(r'dependencies')) {
      inDeps = true;
    }
    if (line.contains('android {')) {
      inAndroid = true;
    }
    if (line.contains('defaultConfig {')) {
      inConfig = true;
    }
    if (line.contains('com.google.firebase:firebase-messaging')) {
      hasMessaging = true;
    }
    if (line.contains('multiDexEnabled')) {
      hasMultidex = true;
    }
    if (line.contains('com.google.gms.google-serices')) {
      hasGMSServices = true;
    }
    if (line.contains('subprojects {')) {
      hasSubprojects = true;
    }

    if (hasFirebase && !hasMultidex) {
      if (inAndroid && inConfig && line.contains('}')) {
        var re = RegExp(r'(\s)', caseSensitive: false);
        var tabs = re.allMatches(line);
        // print('tabs ${tabs.length}');
        var spacer = ' ' * (tabs.isNotEmpty ? tabs.length * 2 : GRADLE_INDENT);
        newLines.add('${spacer}multiDexEnabled true');
        inAndroid = false;
        inConfig = false;
      }
    }

    if (hasFirebaseMessages && !hasMessaging) {
      if (inDeps && line.contains('}')) {
        var re = RegExp(r'(\s)', caseSensitive: false);
        var tabs = re.allMatches(line);
        // print('tabs ${tabs.length}');
        var spacer = ' ' * (tabs.isNotEmpty ? tabs.length * 2 : GRADLE_INDENT);
        newLines.add(
            "${spacer}implementation 'com.google.firebase:firebase-messaging:20.2.4'");

        inDeps = false;
      }
    }
    newLines.add(line);
  }

  if (hasFirebaseMessages && !hasGMSServices) {
    newLines.add('');
    newLines.add("apply plugin: 'com.google.gms.google-serices'");
  }

  if (!hasSubprojects && hasFirebase) {
    newLines.add('');
    newLines.add('''subprojects {
    project.configurations.all {
        resolutionStrategy.eachDependency { details ->
            if (details.requested.group == 'com.android.support'
                    && !details.requested.name.contains('multidex') ) {
                details.useVersion "26.1.0"
            }
        }
    }
}''');
  }

  appGradle.writeAsStringSync(newLines.join('\n'));
}

// String _getFile(String filePathAndName) {
//   final file = File.fromUri(Uri.file(filePathAndName, windows: true));
//   final fileData = file.readAsStringSync();
//   return fileData;
// }

Pubspec getPubspec(String projectPath) {
  var fs = const LocalFileSystem();
  var fileData = fs
      .directory(p.absolute(projectPath))
      .childFile('pubspec.yaml')
      .readAsStringSync();
  final result = Pubspec.parse(fileData);
  return result;
}

Directory getAndroidPath(Directory fs) {
  return fs.childDirectory('android');
}

File getRootGradle(String projectPath) {
  var fs = const LocalFileSystem();
  return fs
      .directory(p.absolute(projectPath))
      .childDirectory('android')
      .childFile('build.gradle');
}

File getAppGradle(String projectPath) {
  var fs = const LocalFileSystem();
  return fs
      .directory(p.absolute(projectPath))
      .childDirectory('android')
      .childDirectory('app')
      .childFile('build.gradle');
}

File getManifest(String projectPath) {
  var fs = const LocalFileSystem();
  return fs
      .directory(p.absolute(projectPath))
      .childDirectory('android')
      .childDirectory('app')
      .childDirectory('src')
      .childDirectory('main')
      .childFile('AndroidManifest.xml');
}
