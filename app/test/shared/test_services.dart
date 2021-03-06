// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:gcloud/db.dart';
import 'package:gcloud/service_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'package:pub_dev/frontend/handlers.dart';
import 'package:pub_dev/frontend/handlers/pubapi.client.dart';
import 'package:pub_dev/package/name_tracker.dart';
import 'package:pub_dev/scorecard/backend.dart';
import 'package:pub_dev/search/backend.dart';
import 'package:pub_dev/search/handlers.dart';
import 'package:pub_dev/search/updater.dart';
import 'package:pub_dev/shared/configuration.dart';
import 'package:pub_dev/shared/handler_helpers.dart';
import 'package:pub_dev/shared/integrity.dart';
import 'package:pub_dev/shared/popularity_storage.dart';
import 'package:pub_dev/search/search_client.dart';
import 'package:pub_dev/service/services.dart';
import 'package:pub_dev/tool/test_profile/import_source.dart';
import 'package:pub_dev/tool/test_profile/importer.dart';
import 'package:pub_dev/tool/test_profile/models.dart';
import 'package:pub_dev/tool/utils/http.dart';
import 'package:test/test.dart';

import '../shared/utils.dart';
import 'test_models.dart';

/// Registers test with [name] and runs it in pkg/fake_gcloud's scope, populated
/// with [testProfile] data.
void testWithProfile(
  String name, {
  TestProfile testProfile,
  ImportSource importSource,
  @required Future<void> Function() fn,
  Timeout timeout,
}) {
  testWithServices(
    name,
    () async {
      await importProfile(
        profile: testProfile ?? defaultTestProfile,
        source: importSource ?? ImportSource.autoGenerated(),
      );
      await nameTracker.scanDatastore();

      await fork(() async {
        await fn();
      });
    },
    omitData: true,
    timeout: timeout,
  );
}

/// Setup scoped services for tests.
///
/// If [omitData] is not set to `true`, a default set of user and package data
/// will be populated and indexed in search.
void testWithServices(
  String name,
  Future<void> Function() fn, {
  bool omitData = false,
  Timeout timeout,
}) {
  scopedTest(name, () async {
    _setupLogging();
    await withFakeServices(
        configuration: Configuration.test(),
        fn: () async {
          if (!omitData) {
            await _populateDefaultData();
          }
          await dartSdkIndex.markReady();
          await indexUpdater.updateAllPackages();

          registerSearchClient(
              SearchClient(_httpClient(handler: searchServiceHandler)));

          registerScopeExitCallback(searchClient.close);

          await fork(() async {
            await fn();
            // post-test integrity check
            final problems = await IntegrityChecker(dbService).check();
            if (problems.isNotEmpty) {
              throw Exception(
                  '${problems.length} integrity problems detected. First: ${problems.first}');
            }
          });
        });
  }, timeout: timeout);
}

Future<void> _populateDefaultData() async {
  await dbService.commit(inserts: [
    foobarPackage,
    foobarStablePV,
    foobarDevPV,
    ...pvModels(foobarStablePV),
    ...pvModels(foobarDevPV),
    foobarStablePvInfo,
    foobarDevPvInfo,
    ...foobarAssets.values,
    testUserA,
    hansUser,
    joeUser,
    adminUser,
    adminOAuthUserID,
    hydrogen.package,
    ...hydrogen.versions.map(pvModels).expand((m) => m),
    ...hydrogen.infos,
    ...hydrogen.assets,
    helium.package,
    ...helium.versions.map(pvModels).expand((m) => m),
    ...helium.infos,
    ...helium.assets,
    lithium.package,
    ...lithium.versions.map(pvModels).expand((m) => m),
    ...lithium.infos,
    ...lithium.assets,
    exampleComPublisher,
    exampleComHansAdmin,
  ]);

  popularityStorage.updateValues({
    hydrogen.package.name: 0.8,
    helium.package.name: 1.0,
    lithium.package.name: 0.7,
  });

  await scoreCardBackend.updateReport(
      helium.package.name,
      helium.package.latestVersion,
      generatePanaReport(derivedTags: ['sdk:flutter']));
  await scoreCardBackend.updateScoreCard(
      helium.package.name, helium.package.latestVersion);
}

/// Creates local, non-HTTP-based API client with [authToken].
PubApiClient createPubApiClient({String authToken}) =>
    PubApiClient('http://localhost:0/',
        client: _httpClient(authToken: authToken));

/// Returns a HTTP client that bridges HTTP requests and shelf handlers without
/// the actual HTTP transport layer.
///
/// If [handler] is not specified, it will use the default frontend handler.
http.Client _httpClient({
  shelf.Handler handler,
  String authToken,
}) {
  handler ??= createAppHandler();
  handler = wrapHandler(
    Logger.detached('test'),
    handler,
    sanitize: true,
  );
  return httpClientWithAuthorization(
    tokenProvider: () async => authToken,
    client: http_testing.MockClient(_wrapShelfHandler(handler)),
  );
}

String _removeLeadingSlashes(String path) {
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  return path;
}

http_testing.MockClientHandler _wrapShelfHandler(shelf.Handler handler) {
  return (rq) async {
    final shelfRq = shelf.Request(
      rq.method,
      rq.url.replace(path: _removeLeadingSlashes(rq.url.path)),
      body: rq.body,
      headers: rq.headers,
      url: Uri(path: _removeLeadingSlashes(rq.url.path), query: rq.url.query),
      handlerPath: '',
    );
    shelf.Response rs;
    // Need to fork a service scope to create a separate RequestContext in the
    // search service handler.
    await fork(() async {
      rs = await handler(shelfRq);
    });
    return http.Response(
      await rs.readAsString(),
      rs.statusCode,
      headers: rs.headers,
    );
  };
}

bool _loggingDone = false;

/// Setup logging if environment variable `DEBUG` is defined.
void _setupLogging() {
  if (_loggingDone) {
    return;
  }
  _loggingDone = true;
  if ((Platform.environment['DEBUG'] ?? '') == '') {
    return;
  }
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    print('${rec.level.name}: ${rec.time}: ${rec.message}');
    if (rec.error != null) {
      print('ERROR: ${rec.error}, ${rec.stackTrace}');
    }
  });
}
