import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playce_mobile/main.dart';
import 'package:playce_mobile/playce_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders the customer navigation and empty cart state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = PlayceState()
      ..loadingCatalog = false
      ..loadingPlans = false;
    await app.initialize();
    addTearDown(app.dispose);

    await tester.pumpWidget(PlayceApp(app: app));

    expect(find.text('playce'), findsOneWidget);
    expect(find.text('Todos os jogos'), findsOneWidget);
    expect(find.text('Loja'), findsOneWidget);
    expect(find.text('Planos'), findsOneWidget);
    expect(find.text('Biblioteca'), findsOneWidget);
    expect(find.text('Carrinho'), findsOneWidget);

    await tester.tap(find.text('Carrinho'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Seu carrinho está vazio.'), findsOneWidget);
  });

  group('PlayceApi', () {
    test('registers using the backend passwordHash field', () async {
      late http.Request capturedRequest;
      final client = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'access_token': 'token',
            'user': {
              'sub': 7,
              'email': 'jogador@example.com',
              'name': 'Jogador',
              'role': 'USER',
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = PlayceApi(client: client);

      final result = await api.authenticate(
        name: 'Jogador',
        email: 'jogador@example.com',
        password: 'senha-segura',
      );

      expect(capturedRequest.url.path, '/api/auth/register');
      expect(capturedRequest.method, 'POST');
      expect(jsonDecode(capturedRequest.body), {
        'name': 'Jogador',
        'email': 'jogador@example.com',
        'passwordHash': 'senha-segura',
      });
      expect(result['access_token'], 'token');
      client.close();
    });

    test('parses catalog games and calculates the current discounted price',
        () {
      final game = Game.fromJson({
        'id': 12,
        'name': 'Aventura',
        'price': 100,
        'currentDiscount': 25,
        'categories': [
          {'id': 1, 'name': 'Ação'},
        ],
        'imageUrl': 'https://example.com/cover.jpg',
      });

      expect(game.id, 12);
      expect(game.categories, ['Ação']);
      expect(game.finalPrice, 75);
    });

    test('uses the greater of the promotion and plan discount', () {
      const game = Game(
        id: 4,
        name: 'Corrida',
        price: 100,
        currentDiscount: 10,
        imageUrl: null,
        categories: [],
      );
      const plan = Plan(
        id: 2,
        name: 'Plus',
        price: 20,
        maxGames: 5,
        minDiscount: 5,
        maxDiscount: 20,
      );

      final quote = PlanPriceQuote.calculate(game, plan);

      expect(quote.storePrice, 90);
      expect(quote.lowestPlanPrice, 80);
      expect(quote.highestPlanPrice, 90);
      expect(quote.storePromotionIsBest, isFalse);
      expect(
        PlanPriceQuote.calculate(
          const Game(
            id: 5,
            name: 'RPG',
            price: 100,
            currentDiscount: 30,
            imageUrl: null,
            categories: [],
          ),
          plan,
        ).storePromotionIsBest,
        isTrue,
      );
    });

    test('creates a checkout using unique game IDs and parses server totals',
        () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/purchases');
        expect(request.headers['authorization'], 'Bearer session-token');
        expect(jsonDecode(request.body), {
          'items': [
            {'gameId': 8},
          ],
        });
        return http.Response(
          jsonEncode({
            'id': 42,
            'totalPrice': 72.5,
            'data': '2026-11-25T10:00:00.000Z',
            'purchases': [
              {
                'gameId': 8,
                'acquisitionPrice': 100,
                'discount': 27.5,
                'game': {
                  'id': 8,
                  'name': 'Aventura',
                  'price': 100,
                  'categories': [],
                },
              },
            ],
          }),
          201,
        );
      });
      final api = PlayceApi(client: client)..token = 'session-token';

      final receipt = await api.checkout([8]);

      expect(receipt.id, 42);
      expect(receipt.totalPrice, 72.5);
      expect(receipt.totalDiscount, 27.5);
      expect(receipt.items.single.finalPrice, 72.5);
      client.close();
    });

    test('rejects duplicate IDs before sending a checkout request', () async {
      final client = MockClient((_) async {
        fail('Duplicate game IDs must not reach the API.');
      });
      final api = PlayceApi(client: client);

      await expectLater(
        api.checkout([3, 3]),
        throwsA(isA<ApiException>()),
      );
      client.close();
    });

    test('subscribes with the authenticated user and parses the 30-day dates',
        () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/plans/2/subscribe');
        expect(request.method, 'POST');
        expect(request.headers['authorization'], 'Bearer session-token');
        return http.Response(
          jsonEncode({
            'id': 5,
            'userId': 7,
            'planId': 2,
            'startedAt': '2026-11-25T10:00:00.000Z',
            'expiresAt': '2026-12-25T10:00:00.000Z',
            'plan': {
              'id': 2,
              'name': 'Plus',
              'price': 19.9,
              'maxGames': 5,
              'minDiscount': 5,
              'maxDiscount': 15,
            },
          }),
          201,
        );
      });
      final api = PlayceApi(client: client)..token = 'session-token';

      final subscription = await api.subscribe(2);

      expect(subscription.userId, 7);
      expect(subscription.plan.id, 2);
      expect(
        subscription.expiresAt.difference(subscription.startedAt).inDays,
        30,
      );
      client.close();
    });
  });
}
