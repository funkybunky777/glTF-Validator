/*
 * # Copyright (c) 2016-2017 The Khronos Group Inc.
 * # Copyright (c) 2016 Alexey Knyazev
 * #
 * # Licensed under the Apache License, Version 2.0 (the "License");
 * # you may not use this file except in compliance with the License.
 * # You may obtain a copy of the License at
 * #
 * #     http://www.apache.org/licenses/LICENSE-2.0
 * #
 * # Unless required by applicable law or agreed to in writing, software
 * # distributed under the License is distributed on an "AS IS" BASIS,
 * # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * # See the License for the specific language governing permissions and
 * # limitations under the License.
 */

// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:gltf/src/errors.dart';
import 'package:grinder/grinder.dart';
import 'package:node_preamble/preamble.dart' as preamble;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

final String _version =
    loadYaml(new File('pubspec.yaml').readAsStringSync())['version'];

Future<void> main(List<String> args) => grind(args);

void _replaceVersion() {
  final f = new File('lib/gltf.dart');
  f.writeAsStringSync(
      f.readAsStringSync().replaceAll('GLTF_VALIDATOR_VERSION', _version));
}

void _restoreVersion() {
  final f = new File('lib/gltf.dart');
  f.writeAsStringSync(
      f.readAsStringSync().replaceAll(_version, 'GLTF_VALIDATOR_VERSION'));
}

@Task('Generate ISSUES.md')
void issues() {
  final sb = new StringBuffer('# glTF 2.0 Validation Issues\n');

  String severityToMdString(Severity severity) =>
      const ['Error', 'Warning', 'Information', 'Hint'][severity.index];

  var total = 0;
  void processErrorClass(Type type) {
    final errorClassMirror = reflectClass(type);
    sb
      ..writeln('## ${errorClassMirror.reflectedType}')
      ..writeln('| Code | Message | Severity |')
      ..writeln('|------|---------|----------|');

    final args = ['`%1`', '`%2`', '`%3`', '`%4`'];
    final argsWithArray = [
      '`%1`',
      ['`%a`', '`%b`', '`%c`'],
      '`%3`',
      '`%4`'
    ];

    final issuesList = new List<IssueType>.from(
        errorClassMirror.staticMembers.keys
            .map<Object>(
                (symbol) => errorClassMirror.getField(symbol).reflectee)
            .where((reflectee) => reflectee is IssueType),
        growable: false)
      ..sort((a, b) => a.code.compareTo(b.code));

    for (final issueType in issuesList) {
      String message;
      try {
        message = issueType.message(args);
        // ignore: avoid_catching_errors
      } on CastError catch (_) {
        message = issueType.message(argsWithArray);
      }
      sb.writeln('|${issueType.code}|$message|'
          '${severityToMdString(issueType.severity)}|');
    }
    total += issuesList.length;
  }

  processErrorClass(IoError);
  processErrorClass(SchemaError);
  processErrorClass(SemanticError);
  processErrorClass(LinkError);
  processErrorClass(DataError);
  processErrorClass(GlbError);

  new File('ISSUES.md').writeAsStringSync(sb.toString(), flush: true);
  log('Total number of issues: $total');
}

@Task('Build Dart snapshot.')
void snapshot() {
  new Directory('build').createSync();

  _replaceVersion();
  Dart.run('bin/gltf_validator.dart',
      vmArgs: ['--snapshot=build/gltf_validator.snapshot']);
  _restoreVersion();
}

@Task('Build web drag-n-drop version.')
void web() {
  _replaceVersion();
  Pub.build();
  _restoreVersion();
}

final _dart2jsArgs = [
  '--minify',
  '--no-source-maps',
  '--trust-primitives',
  '--trust-type-annotations'
];

const _sourceDir = 'tool/npm_template';
const _destDir = 'build/npm/';
final _dir = new Directory(_destDir);

@Task('Build non-minified npm package with source map.')
void npmDebug() {
  _dart2jsArgs
    ..clear()
    ..add('-DGLTF_VALIDATOR_DEBUG=true');
  npmRelease();
}

@Task('Build minified npm package.')
void npmRelease() {
  if (_dir.existsSync()) {
    _dir.deleteSync(recursive: true);
  }
  _dir.createSync(recursive: true);

  final destination = new File(p.join(_destDir, 'gltf_validator.dart.js'));

  _replaceVersion();

  Dart2js.compile(new File(p.join(_sourceDir, 'node_wrapper.dart')),
      outFile: destination, extraArgs: _dart2jsArgs);

  _restoreVersion();

  final compiledJs = destination.readAsStringSync();

  // Node.js detector adopted from https://github.com/iliakan/detect-node
  const kDetector =
      "Object.prototype.toString.call(typeof process!=='undefined'?process:0)==='[object process]'";
  final preambleJs =
      'if($kDetector){${preamble.getPreamble(minified: true)}}else{var self=global.self;self.exports=exports}';

  destination.writeAsStringSync('$preambleJs\n$compiledJs');

  delete(new File(p.join(_destDir, 'gltf_validator.dart.js.deps')));

  final Map<String, Object> jsonMap = json
      .decode(new File(p.join(_sourceDir, 'package.json')).readAsStringSync());
  jsonMap['version'] = _version;

  log('copying package.json to $_destDir');
  new File(p.join(_destDir, 'package.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('    ').convert(jsonMap));

  copy(new File(p.join(_sourceDir, 'index.js')), _dir);
}

@Depends(issues, npmRelease)
@Task('Build an npm package.')
void npm() {
  log('Building npm README...');
  copy(new File(p.join(_sourceDir, 'README.md')), _dir);
  run(npmExecutable,
      arguments: ['install'], workingDirectory: 'tool/npm_template');
  run(npmExecutable,
      arguments: ['run', 'docs'], workingDirectory: 'tool/npm_template');

  copy(new File('ISSUES.md'), _dir);
  copy(new File('LICENSE'), _dir);
  copy(new File('3RD_PARTY'), _dir);
  copy(new File(p.join('docs', 'validation.schema.json')), _dir);
}

@Depends(npm)
@Task('Publish package to npm.')
void npmPublish() {
  run(npmExecutable, arguments: ['publish'], workingDirectory: 'build/npm');
}

String get npmExecutable => Platform.isWindows ? 'npm.cmd' : 'npm';
