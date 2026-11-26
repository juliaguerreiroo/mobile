import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playce_api.dart';

const purple = Color(0xFF7C3AED);
const darkBackground = Color(0xFF0F0C1B);
const cardBackground = Color(0xFF1A162B);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = PlayceState();
  await app.initialize();
  runApp(PlayceApp(app: app));
  unawaited(app.loadCatalog());
  unawaited(app.loadPlans());
  if (app.user != null) unawaited(app.loadPersonal());
}

class PlayceState extends ChangeNotifier {
  final api = PlayceApi();
  List<Game> games = [];
  List<Plan> plans = [];
  List<Library> libraries = [];
  List<PlanGame> planGames = [];
  List<int> cartIds = [];
  Map<String, dynamic>? user;
  bool isDark = false;
  bool loadingCatalog = true;
  bool loadingPlans = true;
  bool loadingLibrary = false;
  bool personalReady = false;
  String? catalogError;
  String? plansError;
  String? libraryError;
  String? cartNotice;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    isDark = preferences.getBool('playce_dark_mode') ?? false;
    cartIds = preferences
            .getStringList('playce_cart')
            ?.map(int.tryParse)
            .whereType<int>()
            .where((id) => id > 0)
            .toList() ??
        [];
    final savedSession = preferences.getString('playce_session');
    if (savedSession != null) {
      try {
        final session = _decodeSession(savedSession);
        final token = session['access_token'];
        final savedUser = session['user'];
        if (token is String && savedUser is Map) {
          api.token = token;
          user = Map<String, dynamic>.from(savedUser);
        } else {
          await preferences.remove('playce_session');
        }
      } catch (_) {
        await preferences.remove('playce_session');
      }
    }
    api.onUnauthorized = () => logout();
  }

  Future<void> loadCatalog() async {
    loadingCatalog = true;
    catalogError = null;
    notifyListeners();
    try {
      games = await api.games();
      _pruneUnavailableCartItems();
    } on ApiException catch (error) {
      catalogError = error.message;
    } finally {
      loadingCatalog = false;
      notifyListeners();
    }
  }

  Future<void> loadPlans() async {
    loadingPlans = true;
    plansError = null;
    notifyListeners();
    try {
      plans = await api.plans();
    } on ApiException catch (error) {
      plansError = error.message;
    } finally {
      loadingPlans = false;
      notifyListeners();
    }
  }

  Future<void> loadPersonal() async {
    if (user == null) return;
    loadingLibrary = true;
    libraryError = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.libraries(),
        api.planGames(),
      ]);
      libraries = results[0] as List<Library>;
      planGames = results[1] as List<PlanGame>;
      personalReady = true;
      _pruneUnavailableCartItems();
    } on ApiException catch (error) {
      libraryError = error.message;
    } finally {
      loadingLibrary = false;
      notifyListeners();
    }
  }

  Future<void> authenticate({
    required String email,
    required String password,
    String? name,
  }) async {
    final session = await api.authenticate(
      email: email,
      password: password,
      name: name,
    );
    final token = session['access_token'];
    final account = session['user'];
    if (token is! String || account is! Map) {
      throw const ApiException('A API retornou uma sessão inválida.');
    }
    api.token = token;
    user = Map<String, dynamic>.from(account);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('playce_session', _encodeSession(session));
    notifyListeners();
    await loadPersonal();
  }

  Future<void> logout() async {
    api.token = null;
    user = null;
    libraries = [];
    planGames = [];
    personalReady = false;
    libraryError = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('playce_session');
    notifyListeners();
  }

  Future<void> addToCart(int id) async {
    if (!games.any((game) => game.id == id)) {
      throw const ApiException('Este jogo não está mais disponível na loja.');
    }
    if (isPurchased(id)) {
      throw const ApiException('Este jogo já está na sua biblioteca.');
    }
    if (!cartIds.contains(id)) cartIds = [...cartIds, id];
    cartNotice = null;
    await _saveCart();
  }

  Future<void> removeFromCart(int id) async {
    cartIds = cartIds.where((item) => item != id).toList();
    cartNotice = null;
    await _saveCart();
  }

  Future<void> clearCart() async {
    cartIds = [];
    cartNotice = null;
    await _saveCart();
  }

  Future<void> _saveCart() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      'playce_cart',
      cartIds.map((id) => '$id').toList(),
    );
    notifyListeners();
  }

  Future<PurchaseReceipt> checkout() async {
    if (user == null) {
      throw const ApiException('Entre na sua conta para finalizar a compra.');
    }
    if (cartIds.isEmpty) {
      throw const ApiException('Adicione ao menos um jogo antes de comprar.');
    }
    if (cartIds.toSet().length != cartIds.length) {
      throw const ApiException('O carrinho contém jogos repetidos.');
    }
    if (cartIds.any(isPurchased)) {
      throw const ApiException('Remova do carrinho os jogos já adquiridos.');
    }
    final receipt = await api.checkout(cartIds);
    final boughtIds = receipt.items.map((item) => item.gameId).toSet();
    cartIds = cartIds.where((id) => !boughtIds.contains(id)).toList();
    cartNotice = null;
    await _saveCart();
    await loadPersonal();
    return receipt;
  }

  Future<PlanSubscription> subscribe(Plan plan) async {
    if (user == null) {
      throw const ApiException('Entre na sua conta para assinar um plano.');
    }
    final subscription = await api.subscribe(plan.id);
    if (subscription.id <= 0 ||
        subscription.planId != plan.id ||
        subscription.userId != _asInt(user?['sub']) ||
        !subscription.expiresAt.isAfter(subscription.startedAt)) {
      throw const ApiException(
        'A API retornou uma confirmação de assinatura inválida.',
      );
    }
    await loadPersonal();
    return subscription;
  }

  Future<DownloadResult> download(Library library, Game game) async {
    final result = await api.download(library.id, game.id);
    await loadPersonal();
    return result;
  }

  bool isPurchased(int gameId) => libraries
      .any((library) => library.games.any((entry) => entry.game.id == gameId));

  Plan? discountPlanFor(int gameId) {
    for (final entry in planGames) {
      if (entry.game.id == gameId) {
        for (final plan in plans) {
          if (plan.id == entry.planId) return plan;
        }
      }
    }
    return null;
  }

  double priceFor(Game game) {
    final plan = discountPlanFor(game.id);
    if (plan == null) return game.finalPrice;
    return PlanPriceQuote.calculate(game, plan).highestPlanPrice;
  }

  double lowestPriceFor(Game game) {
    final plan = discountPlanFor(game.id);
    if (plan == null) return game.finalPrice;
    return PlanPriceQuote.calculate(game, plan).lowestPlanPrice;
  }

  Future<void> toggleTheme() async {
    isDark = !isDark;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('playce_dark_mode', isDark);
    notifyListeners();
  }

  void _pruneUnavailableCartItems() {
    if (loadingCatalog || (user != null && !personalReady)) return;
    final availableIds = games.map((game) => game.id).toSet();
    final filteredIds = cartIds
        .where((id) => availableIds.contains(id) && !isPurchased(id))
        .toSet()
        .toList();
    if (filteredIds.length == cartIds.length) return;
    cartIds = filteredIds;
    cartNotice =
        'Jogos indisponíveis ou já adquiridos foram retirados do carrinho.';
    unawaited(_saveCart());
  }
}

class PlayceApp extends StatelessWidget {
  const PlayceApp({super.key, required this.app});

  final PlayceState app;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: app,
        builder: (context, _) => MaterialApp(
          title: 'Playce',
          debugShowCheckedModeBanner: false,
          theme: _playceTheme(Brightness.light),
          darkTheme: _playceTheme(Brightness.dark),
          themeMode: app.isDark ? ThemeMode.dark : ThemeMode.light,
          home: StoreShell(app: app),
        ),
      );
}

class StoreShell extends StatefulWidget {
  const StoreShell({super.key, required this.app});

  final PlayceState app;

  @override
  State<StoreShell> createState() => _StoreShellState();
}

class _StoreShellState extends State<StoreShell> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      StorePage(app: widget.app),
      PlansPage(app: widget.app),
      LibraryPage(app: widget.app),
      CartPage(app: widget.app),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'playce',
          style: TextStyle(color: purple, fontWeight: FontWeight.w900),
        ),
        actions: [
          if (widget.app.user != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: Text(
                  'Olá, ${widget.app.user?['name'] ?? ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          IconButton(
            tooltip: widget.app.user == null ? 'Entrar' : 'Minha conta',
            icon: Icon(
              widget.app.user == null ? Icons.person_outline : Icons.person,
            ),
            onPressed: () => _openAccount(context),
          ),
        ],
      ),
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => setState(() => selectedIndex = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Loja',
          ),
          const NavigationDestination(
            icon: Icon(Icons.workspace_premium_outlined),
            selectedIcon: Icon(Icons.workspace_premium),
            label: 'Planos',
          ),
          const NavigationDestination(
            icon: Icon(Icons.videogame_asset_outlined),
            selectedIcon: Icon(Icons.videogame_asset),
            label: 'Biblioteca',
          ),
          NavigationDestination(
            icon: Badge(
              label: Text('${widget.app.cartIds.length}'),
              isLabelVisible: widget.app.cartIds.isNotEmpty,
              child: const Icon(Icons.shopping_cart_outlined),
            ),
            selectedIcon: const Icon(Icons.shopping_cart),
            label: 'Carrinho',
          ),
        ],
      ),
    );
  }

  Future<void> _openAccount(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.app.user?['name']?.toString() ?? 'Sua conta Playce',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (widget.app.user case final user?)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    user['email']?.toString() ?? '',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (widget.app.user == null)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('Entrar ou criar conta'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AuthPage(app: widget.app),
                      ),
                    );
                  },
                ),
              if (widget.app.user != null) ...[
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Histórico de compras'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PurchaseHistoryPage(app: widget.app),
                      ),
                    );
                  },
                ),
              ],
              ListTile(
                leading: Icon(
                  widget.app.isDark ? Icons.light_mode : Icons.dark_mode,
                ),
                title: Text(
                  widget.app.isDark ? 'Modo claro' : 'Modo escuro',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.app.toggleTheme();
                },
              ),
              if (widget.app.user != null)
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text('Sair da conta'),
                  textColor: Colors.redAccent,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    widget.app.logout();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class StorePage extends StatefulWidget {
  const StorePage({super.key, required this.app});

  final PlayceState app;

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  String search = '';
  String? selectedCategory;

  @override
  Widget build(BuildContext context) {
    final categories = widget.app.games
        .expand((game) => game.categories)
        .toSet()
        .toList()
      ..sort();
    final promotions = widget.app.games
        .where((game) => game.currentDiscount > 0)
        .take(5)
        .toList();
    final games = widget.app.games
        .where((game) =>
            game.name.toLowerCase().contains(search.toLowerCase()) ||
            game.categories.any(
              (category) =>
                  category.toLowerCase().contains(search.toLowerCase()),
            ))
        .where((game) =>
            selectedCategory == null ||
            game.categories.contains(selectedCategory))
        .toList();
    return RefreshIndicator(
      onRefresh: widget.app.loadCatalog,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF5B21B6),
                  Color(0xFF7C3AED),
                  Color(0xFF312E81)
                ],
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SEU PRÓXIMO JOGO FAVORITO',
                    style: TextStyle(fontSize: 11, letterSpacing: 1.2)),
                SizedBox(height: 8),
                Text('Descubra novos mundos.',
                    style:
                        TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('Jogos, descontos e diversão em um só lugar.'),
              ],
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            onChanged: (value) => setState(() => search = value.trim()),
            decoration: const InputDecoration(
              hintText: 'Buscar jogos ou categorias',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('Todos'),
                      selected: selectedCategory == null,
                      onSelected: (_) =>
                          setState(() => selectedCategory = null),
                    ),
                  ),
                  ...categories.map(
                    (category) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(category),
                        selected: selectedCategory == category,
                        onSelected: (_) => setState(
                          () => selectedCategory =
                              selectedCategory == category ? null : category,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (search.isEmpty &&
              selectedCategory == null &&
              promotions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Ofertas da semana',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            SizedBox(
              height: 184,
              child: PageView.builder(
                itemCount: promotions.length,
                controller: PageController(viewportFraction: .9),
                itemBuilder: (context, index) {
                  final game = promotions[index];
                  final plan = widget.app.discountPlanFor(game.id);
                  final discount = math.max(
                    game.currentDiscount,
                    plan?.minDiscount ?? 0,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              GameDetailsPage(app: widget.app, game: game),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            GameCover(
                              url: game.imageUrl,
                              width: double.infinity,
                              height: 184,
                            ),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xE6000000),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: purple,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    '-${discount.toStringAsFixed(0)}%',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 14,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    game.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    currency(widget.app.priceFor(game)),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            search.isNotEmpty || selectedCategory != null
                ? 'Resultados'
                : 'Todos os jogos',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (widget.app.loadingCatalog && widget.app.games.isEmpty)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(36),
                    child: CircularProgressIndicator()))
          else if (widget.app.catalogError != null && widget.app.games.isEmpty)
            ErrorPanel(
                message: widget.app.catalogError!,
                onRetry: widget.app.loadCatalog)
          else if (games.isEmpty)
            const EmptyPanel(message: 'Nenhum jogo encontrado.')
          else
            ...games.map(
              (game) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GameCard(game: game, app: widget.app),
              ),
            ),
        ],
      ),
    );
  }
}

class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.game,
    required this.app,
    this.displayPlan,
  });

  final Game game;
  final PlayceState app;
  final Plan? displayPlan;

  @override
  Widget build(BuildContext context) {
    final price = displayPlan == null
        ? app.priceFor(game)
        : PlanPriceQuote.calculate(game, displayPlan!).highestPlanPrice;
    final lowestPrice = displayPlan == null
        ? app.lowestPriceFor(game)
        : PlanPriceQuote.calculate(game, displayPlan!).lowestPlanPrice;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GameDetailsPage(
              app: app,
              game: game,
              displayPlan: displayPlan,
            ),
          ),
        ),
        child: SizedBox(
          height: 142,
          child: Row(
            children: [
              GameCover(url: game.imageUrl, width: 104, height: 142),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 5),
                      Text(
                          game.categories.join(' · ').isEmpty
                              ? 'Jogo'
                              : game.categories.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          )),
                      const Spacer(),
                      if (app.isPurchased(game.id))
                        const Text(
                          'Na sua biblioteca',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        Row(
                          children: [
                            if (price < game.price) ...[
                              Text(
                                '-${((1 - price / game.price) * 100).round()}%',
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                                child: Text(
                                    lowestPrice < price
                                        ? '${currency(lowestPrice)}–${currency(price)}'
                                        : currency(price),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))),
                            IconButton.filled(
                              onPressed: () async {
                                try {
                                  await app.addToCart(game.id);
                                } on ApiException catch (error) {
                                  if (context.mounted) {
                                    showError(context, error.message);
                                  }
                                  return;
                                }
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            '${game.name} adicionado ao carrinho.')),
                                  );
                                }
                              },
                              icon:
                                  const Icon(Icons.add_shopping_cart, size: 18),
                              tooltip: 'Adicionar ao carrinho',
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GameDetailsPage extends StatefulWidget {
  const GameDetailsPage({
    super.key,
    required this.app,
    required this.game,
    this.displayPlan,
  });

  final PlayceState app;
  final Game game;
  final Plan? displayPlan;

  @override
  State<GameDetailsPage> createState() => _GameDetailsPageState();
}

class _GameDetailsPageState extends State<GameDetailsPage> {
  late Game game = widget.game;
  bool loading = false;
  String? detailsError;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() {
      loading = true;
      detailsError = null;
    });
    try {
      game = await widget.app.api.game(widget.game.id);
    } on ApiException catch (error) {
      detailsError = error.message;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = <String>{
      if (game.imageUrl?.isNotEmpty == true) game.imageUrl!,
      ...game.screenshots,
    }.toList();
    final plan = widget.displayPlan ?? widget.app.discountPlanFor(game.id);
    return Scaffold(
      appBar: AppBar(title: Text(game.name, maxLines: 1)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (images.isEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: GameCover(
                url: game.imageUrl,
                width: double.infinity,
                height: 230,
              ),
            )
          else
            SizedBox(
              height: 230,
              child: PageView(
                children: images
                    .map(
                      (image) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: GameCover(
                            url: image,
                            width: double.infinity,
                            height: 230,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 20),
          Text(
            game.name,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: game.categories
                .map((category) => Chip(label: Text(category)))
                .toList(),
          ),
          const SizedBox(height: 14),
          Text(
            game.description.isNotEmpty ? game.description : 'Jogo completo',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (game.longDescription.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              game.longDescription,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
            ),
          ],
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Informações do jogo',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text(
                    'Publicado por ${game.ownerName.isEmpty ? 'Playce' : game.ownerName}',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Preço na loja: ${currency(game.price)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (plan != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Com o plano ${plan.name}: ${currency(PlanPriceQuote.calculate(game, plan).lowestPlanPrice)} a ${currency(PlanPriceQuote.calculate(game, plan).highestPlanPrice)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Acesso temporário pelo plano; a compra mantém o jogo na biblioteca.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (detailsError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      loading ? 'Atualizando detalhes...' : detailsError!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (!loading)
                      TextButton(
                        onPressed: _loadDetails,
                        child: const Text('Tentar novamente'),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (widget.app.isPurchased(game.id))
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
              },
              icon: const Icon(Icons.videogame_asset),
              label: const Text('Jogo na sua biblioteca'),
            )
          else
            FilledButton.icon(
              onPressed: () async {
                try {
                  await widget.app.addToCart(game.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Jogo adicionado ao carrinho.'),
                      ),
                    );
                  }
                } on ApiException catch (error) {
                  if (context.mounted) showError(context, error.message);
                }
              },
              icon: const Icon(Icons.add_shopping_cart),
              label: Text(
                'Adicionar ao carrinho · ${currency(widget.app.priceFor(game))}',
              ),
            ),
        ],
      ),
    );
  }
}

class PlansPage extends StatelessWidget {
  const PlansPage({super.key, required this.app});

  final PlayceState app;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: app.loadPlans,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  colors: [Color(0xFF5B21B6), Color(0xFF7C3AED)],
                ),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.workspace_premium, size: 32),
                  SizedBox(height: 10),
                  Text('Mais jogos. Mais vantagens.',
                      style:
                          TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Escolha seu plano Playce por 30 dias.'),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('Compare os planos',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Acesso temporário aos jogos vinculados e descontos exclusivos.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            if (app.loadingPlans && app.plans.isEmpty)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(36),
                      child: CircularProgressIndicator()))
            else if (app.plansError != null && app.plans.isEmpty)
              ErrorPanel(message: app.plansError!, onRetry: app.loadPlans)
            else if (app.plans.isEmpty)
              const EmptyPanel(message: 'Nenhum plano disponível.')
            else
              ...([...app.plans]..sort((a, b) => a.price.compareTo(b.price)))
                  .map(
                (plan) => Card(
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.workspace_premium,
                                color: purple, size: 30),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(plan.name,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold))),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('${currency(plan.price)} / 30 dias',
                            style: Theme.of(context).textTheme.titleLarge),
                        Text('Cobertura de 30 dias, sem renovação automática',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 8),
                        Text(
                            'Acesso a até ${plan.maxGames} ${plan.maxGames == 1 ? 'jogo' : 'jogos'} vinculados'),
                        Text(
                          plan.minDiscount == plan.maxDiscount
                              ? '${plan.minDiscount.toStringAsFixed(0)}% de desconto nas compras'
                              : 'De ${plan.minDiscount.toStringAsFixed(0)}% a ${plan.maxDiscount.toStringAsFixed(0)}% de desconto nas compras',
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PlanDetailsPage(
                                      app: app,
                                      plan: plan,
                                    ),
                                  ),
                                ),
                                child: const Text('Ver jogos'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _subscribe(context, plan),
                                child: const Text('Assinar'),
                              ),
                            ),
                          ],
                        ),
                        if (app.user == null) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Entre na sua conta para ativar a assinatura.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Future<void> _subscribe(BuildContext context, Plan plan) async {
    if (app.user == null) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => AuthPage(app: app)));
    }
    if (context.mounted && app.user != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlanSubscriptionPage(app: app, plan: plan),
        ),
      );
    }
  }
}

class PlanDetailsPage extends StatefulWidget {
  const PlanDetailsPage({super.key, required this.app, required this.plan});

  final PlayceState app;
  final Plan plan;

  @override
  State<PlanDetailsPage> createState() => _PlanDetailsPageState();
}

class _PlanDetailsPageState extends State<PlanDetailsPage> {
  List<PlanGame> games = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadGames();
  }

  Future<void> _loadGames() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      games = await widget.app.api.gamesForPlan(widget.plan.id);
    } on ApiException catch (exception) {
      error = exception.message;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.plan.name)),
        body: RefreshIndicator(
          onRefresh: _loadGames,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5B21B6), Color(0xFF7C3AED)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Plano ${widget.plan.name}',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Text('${currency(widget.plan.price)} por 30 dias'),
                    const SizedBox(height: 12),
                    Text(
                      'Acesso temporário a até ${widget.plan.maxGames} jogos.',
                    ),
                    Text(
                      'Desconto de ${widget.plan.minDiscount.toStringAsFixed(0)}% a ${widget.plan.maxDiscount.toStringAsFixed(0)}% nas compras de jogos vinculados.',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Jogos comprados permanecem na sua biblioteca após a assinatura expirar.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Jogos do plano',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text('${games.length}'),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'O acesso aos jogos é temporário. Comprar um jogo mantém o acesso na biblioteca.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (loading && games.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (error != null && games.isEmpty)
                ErrorPanel(message: error!, onRetry: _loadGames)
              else if (games.isEmpty)
                const EmptyPanel(
                  message: 'Nenhum jogo está vinculado a este plano.',
                )
              else
                ...games.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GameCard(
                      game: entry.game,
                      app: widget.app,
                      displayPlan: widget.plan,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _subscribe(context),
                child: const Text('Continuar para assinatura'),
              ),
            ],
          ),
        ),
      );

  Future<void> _subscribe(BuildContext context) async {
    if (widget.app.user == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AuthPage(app: widget.app)),
      );
    }
    if (!context.mounted || widget.app.user == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PlanSubscriptionPage(app: widget.app, plan: widget.plan),
      ),
    );
  }
}

class PlanSubscriptionPage extends StatefulWidget {
  const PlanSubscriptionPage({
    super.key,
    required this.app,
    required this.plan,
  });

  final PlayceState app;
  final Plan plan;

  @override
  State<PlanSubscriptionPage> createState() => _PlanSubscriptionPageState();
}

class _PlanSubscriptionPageState extends State<PlanSubscriptionPage> {
  PlanSubscription? subscription;
  bool submitting = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final confirmed = subscription;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirmar assinatura')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (confirmed == null) ...[
            _SummaryCard(
              title: 'Sua conta',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.app.user?['name']?.toString() ?? ''),
                  Text(widget.app.user?['email']?.toString() ?? ''),
                  const SizedBox(height: 6),
                  Text(
                    'A assinatura será ativada nesta conta.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _SummaryCard(
              title: 'Forma de pagamento',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.qr_code_2, color: purple),
                title: Text('Pix'),
                subtitle: Text('Demonstração: nenhuma cobrança será realizada'),
                trailing: Icon(Icons.check_circle, color: purple),
              ),
            ),
            const SizedBox(height: 12),
            _SummaryCard(
              title: 'Resumo do plano',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.plan.name,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Validade de 30 dias · sem renovação automática'),
                  const SizedBox(height: 12),
                  Text('Até ${widget.plan.maxGames} jogos vinculados'),
                  Text(
                    'Descontos de ${widget.plan.minDiscount.toStringAsFixed(0)}% a ${widget.plan.maxDiscount.toStringAsFixed(0)}%',
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total'),
                      Text(
                        currency(widget.plan.price),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: submitting ? null : _confirm,
              child: submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Confirmar assinatura'),
            ),
          ] else ...[
            const Icon(Icons.check_circle, color: Colors.green, size: 48),
            const SizedBox(height: 12),
            Text(
              'Assinatura confirmada',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            _SummaryCard(
              title: 'Detalhes',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(label: 'Plano', value: confirmed.plan.name),
                  _DetailRow(
                    label: 'Valor',
                    value: currency(confirmed.plan.price),
                  ),
                  _DetailRow(
                    label: 'Ativada em',
                    value: formatDate(confirmed.startedAt),
                  ),
                  _DetailRow(
                    label: 'Válida até',
                    value: formatDate(confirmed.expiresAt),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'O desconto final é calculado na compra; entre o desconto da loja e o do plano, vale o maior. Os jogos comprados permanecem na biblioteca após a expiração.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlanDetailsPage(
                    app: widget.app,
                    plan: confirmed.plan,
                  ),
                ),
              ),
              child: const Text('Ver jogos do plano'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar à loja'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirm() async {
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      subscription = await widget.app.subscribe(widget.plan);
    } on ApiException catch (exception) {
      error = exception.message;
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.app});

  final PlayceState app;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String search = '';
  int? downloadingId;

  @override
  Widget build(BuildContext context) {
    final purchased = <int, MapEntry<Library, LibraryGame>>{};
    for (final library in widget.app.libraries) {
      for (final entry in library.games) {
        purchased[entry.game.id] = MapEntry(library, entry);
      }
    }
    final games = <Game>[
      ...purchased.values.map((entry) => entry.value.game),
      ...widget.app.planGames
          .map((entry) => entry.game)
          .where((game) => !purchased.containsKey(game.id)),
    ];
    final filteredGames = games
        .where((game) => game.name.toLowerCase().contains(search.toLowerCase()))
        .toList();
    final hoursPlayed = widget.app.libraries.fold<double>(
      0,
      (total, library) => total + library.totalHoursPlayed,
    );
    return RefreshIndicator(
      onRefresh: widget.app.loadPersonal,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Minha biblioteca',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (widget.app.user != null) ...[
            const SizedBox(height: 12),
            _SummaryCard(
              title: 'Seu progresso',
              child: Row(
                children: [
                  const Icon(Icons.schedule, color: purple),
                  const SizedBox(width: 10),
                  Text('${hoursPlayed.toStringAsFixed(1)} horas jogadas'),
                  const Spacer(),
                  Text('${games.length} jogos'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (value) => setState(() => search = value.trim()),
              decoration: const InputDecoration(
                hintText: 'Buscar na biblioteca',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (widget.app.user == null)
            EmptyPanel(
              message: 'Entre na sua conta para acessar seus jogos.',
              action: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AuthPage(app: widget.app))),
                child: const Text('Entrar'),
              ),
            )
          else if (widget.app.loadingLibrary && games.isEmpty)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(36),
                    child: CircularProgressIndicator()))
          else if (widget.app.libraryError != null && games.isEmpty)
            ErrorPanel(
                message: widget.app.libraryError!,
                onRetry: widget.app.loadPersonal)
          else if (games.isEmpty)
            const EmptyPanel(
                message:
                    'Sua biblioteca está vazia. Explore a loja e encontre seu próximo jogo.')
          else if (filteredGames.isEmpty)
            const EmptyPanel(message: 'Nenhum jogo corresponde à busca.')
          else
            ...filteredGames.map((game) {
              final item = purchased[game.id];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(10),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: GameCover(url: game.imageUrl, width: 54, height: 70),
                  ),
                  title: Text(game.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(item == null
                      ? 'Acesso pelo plano'
                      : 'Adquirido · ${item.value.timePlayed} min jogados'),
                  trailing: item == null
                      ? const Icon(Icons.workspace_premium, color: purple)
                      : IconButton(
                          tooltip: 'Simular download',
                          onPressed: downloadingId == game.id
                              ? null
                              : () => _download(context, item.key, game),
                          icon: downloadingId == game.id
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.download),
                        ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Future<void> _download(
      BuildContext context, Library library, Game game) async {
    setState(() => downloadingId = game.id);
    try {
      final result = await widget.app.download(library, game);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Download simulado: ${result.gameName}. ${result.timePlayed} minutos jogados.',
            ),
          ),
        );
      }
    } on ApiException catch (error) {
      if (context.mounted) showError(context, error.message);
    } finally {
      if (mounted) setState(() => downloadingId = null);
    }
  }
}

class CartPage extends StatelessWidget {
  const CartPage({super.key, required this.app});

  final PlayceState app;

  @override
  Widget build(BuildContext context) {
    final games = app.cartIds
        .map((id) {
          for (final game in app.games) {
            if (game.id == id) return game;
          }
          return null;
        })
        .whereType<Game>()
        .toList();
    final subtotal = games.fold<double>(0, (sum, game) => sum + game.price);
    final total = games.fold<double>(
      0,
      (sum, game) => sum + app.priceFor(game),
    );
    final lowestTotal = games.fold<double>(
      0,
      (sum, game) => sum + app.lowestPriceFor(game),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Carrinho',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (app.cartNotice != null) ...[
          const SizedBox(height: 8),
          Text(
            app.cartNotice!,
            style: const TextStyle(color: Colors.orange),
          ),
        ],
        const SizedBox(height: 12),
        if (app.cartIds.isEmpty)
          const EmptyPanel(
              message:
                  'Seu carrinho está vazio. Explore a loja e encontre seu próximo jogo.')
        else if (games.isEmpty)
          const EmptyPanel(
              message:
                  'Atualize o catálogo para carregar os itens do seu carrinho.')
        else ...[
          ...games.map(
            (game) => Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                contentPadding: const EdgeInsets.all(10),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GameCover(url: game.imageUrl, width: 48, height: 62),
                ),
                title: Text(game.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  app.priceFor(game) == game.price
                      ? currency(game.price)
                      : '${currency(app.priceFor(game))} · de ${currency(game.price)}',
                ),
                trailing: IconButton(
                  tooltip: 'Remover',
                  onPressed: () => app.removeFromCart(game.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _SummaryCard(
            title: 'Resumo do pedido',
            child: Column(
              children: [
                _DetailRow(
                  label:
                      'Subtotal (${games.length} ${games.length == 1 ? 'item' : 'itens'})',
                  value: currency(subtotal),
                ),
                _DetailRow(
                  label: 'Descontos estimados',
                  value: currency(subtotal - total),
                ),
                const _DetailRow(label: 'Taxas adicionais', value: 'R\$ 0,00'),
                const Divider(height: 24),
                _DetailRow(
                  label: 'Total estimado',
                  value: currency(total),
                  emphasized: true,
                ),
              ],
            ),
          ),
          if (lowestTotal < total) ...[
            const SizedBox(height: 8),
            Text(
              'Com o desconto do seu plano, o total pode variar entre ${currency(lowestTotal)} e ${currency(total)}. O servidor calcula o desconto final ao confirmar.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'Pagamento demonstrativo. Não há cobrança real.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: app.user == null
                ? () => _loginAndCheckout(context)
                : app.loadingLibrary || app.libraryError != null
                    ? app.loadPersonal
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CheckoutPage(app: app),
                          ),
                        ),
            icon: const Icon(Icons.lock_outline),
            label: Text(
              app.user == null
                  ? 'Entre para finalizar'
                  : app.loadingLibrary
                      ? 'Verificando sua biblioteca...'
                      : app.libraryError != null
                          ? 'Tentar novamente'
                          : 'Continuar para confirmação',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _loginAndCheckout(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AuthPage(app: app)),
    );
    if (!context.mounted || app.user == null) return;
    await app.loadPersonal();
    if (!context.mounted) return;
    if (app.libraryError != null) {
      showError(context, app.libraryError!);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CheckoutPage(app: app)),
    );
  }
}

class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key, required this.app});

  final PlayceState app;

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  PurchaseReceipt? receipt;
  bool submitting = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final items = app.cartIds
        .map((id) => app.games.where((game) => game.id == id))
        .where((matches) => matches.isNotEmpty)
        .map((matches) => matches.first)
        .toList();
    final subtotal = items.fold<double>(0, (sum, item) => sum + item.price);
    final estimated = items.fold<double>(
      0,
      (sum, item) => sum + app.priceFor(item),
    );
    final minEstimate = items.fold<double>(
      0,
      (sum, item) => sum + app.lowestPriceFor(item),
    );
    final confirmed = receipt;

    return Scaffold(
      appBar: AppBar(
        title:
            Text(confirmed == null ? 'Confirmar compra' : 'Pedido confirmado'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (confirmed != null) ...[
            const Icon(Icons.check_circle, color: Colors.green, size: 52),
            const SizedBox(height: 12),
            Text(
              'Compra confirmada',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
                'Pedido #${confirmed.id} · ${formatDate(confirmed.purchasedAt)}'),
            const SizedBox(height: 12),
            _SummaryCard(
              title: 'Itens adquiridos',
              child: Column(
                children: confirmed.items
                    .map(
                      (item) => _DetailRow(
                        label: item.game.name,
                        value: currency(item.finalPrice),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
            _SummaryCard(
              title: 'Pagamento',
              child: Column(
                children: [
                  _DetailRow(
                    label: 'Descontos aplicados',
                    value: currency(confirmed.totalDiscount),
                  ),
                  _DetailRow(
                    label: 'Total do pedido',
                    value: currency(confirmed.totalPrice),
                    emphasized: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Compra demonstrativa: nenhuma cobrança foi realizada.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => PurchaseHistoryPage(app: app),
                  ),
                );
              },
              icon: const Icon(Icons.receipt_long),
              label: const Text('Ver compras'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar à loja'),
            ),
          ] else if (items.isEmpty)
            EmptyPanel(
              message: 'Seu carrinho está vazio.',
              action: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Voltar para o carrinho'),
              ),
            )
          else ...[
            _SummaryCard(
              title: 'Sua conta',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.user?['name']?.toString() ?? ''),
                  Text(app.user?['email']?.toString() ?? ''),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _SummaryCard(
              title: 'Forma de pagamento',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.qr_code_2, color: purple),
                title: Text('Pix'),
                subtitle: Text('Demonstração, sem cobrança real'),
                trailing: Icon(Icons.check_circle, color: purple),
              ),
            ),
            const SizedBox(height: 12),
            _SummaryCard(
              title: 'Resumo do pedido',
              child: Column(
                children: [
                  ...items.map(
                    (item) => _DetailRow(
                      label: item.name,
                      value: currency(app.priceFor(item)),
                    ),
                  ),
                  const Divider(height: 24),
                  _DetailRow(label: 'Subtotal', value: currency(subtotal)),
                  _DetailRow(
                    label: 'Descontos estimados',
                    value: currency(subtotal - estimated),
                  ),
                  _DetailRow(
                    label: 'Total estimado',
                    value: currency(estimated),
                    emphasized: true,
                  ),
                ],
              ),
            ),
            if (minEstimate < estimated) ...[
              const SizedBox(height: 8),
              Text(
                'O desconto do plano varia. O total final será calculado pelo servidor e exibido após a confirmação (${currency(minEstimate)} a ${currency(estimated)} estimados).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: submitting ? null : _confirmPurchase,
              icon: const Icon(Icons.lock_outline),
              label: submitting
                  ? const Text('Confirmando...')
                  : const Text('Confirmar compra'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmPurchase() async {
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      receipt = await widget.app.checkout();
    } on ApiException catch (exception) {
      error = exception.message;
      if (exception.statusCode == 409) {
        await widget.app.loadPersonal();
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class PurchaseHistoryPage extends StatefulWidget {
  const PurchaseHistoryPage({super.key, required this.app});

  final PlayceState app;

  @override
  State<PurchaseHistoryPage> createState() => _PurchaseHistoryPageState();
}

class _PurchaseHistoryPageState extends State<PurchaseHistoryPage> {
  List<PurchaseReceipt> purchases = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadPurchases();
  }

  Future<void> _loadPurchases() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      purchases = await widget.app.api.purchases();
    } on ApiException catch (exception) {
      error = exception.message;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Histórico de compras')),
        body: RefreshIndicator(
          onRefresh: _loadPurchases,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (loading && purchases.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(36),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (error != null && purchases.isEmpty)
                ErrorPanel(message: error!, onRetry: _loadPurchases)
              else if (purchases.isEmpty)
                const EmptyPanel(message: 'Você ainda não fez compras.')
              else
                ...purchases.map(
                  (purchase) => Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ExpansionTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0x147C3AED),
                        child: Icon(Icons.receipt_long, color: purple),
                      ),
                      title: Text('Pedido #${purchase.id}'),
                      subtitle: Text(
                        '${formatDate(purchase.purchasedAt)} · ${purchase.items.length} ${purchase.items.length == 1 ? 'jogo' : 'jogos'}',
                      ),
                      trailing: Text(
                        currency(purchase.totalPrice),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        ...purchase.items.map(
                          (item) => _DetailRow(
                            label: item.game.name,
                            value: currency(item.finalPrice),
                          ),
                        ),
                        const Divider(),
                        _DetailRow(
                          label: 'Descontos aplicados',
                          value: currency(purchase.totalDiscount),
                        ),
                      ],
                    ),
                  ),
                ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      );
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.app});

  final PlayceState app;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool register = false;
  bool submitting = false;
  bool obscurePassword = true;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(register ? 'Criar conta' : 'Entrar')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Form(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.videogame_asset, color: purple, size: 58),
                  const SizedBox(height: 12),
                  Text(register ? 'Junte-se à Playce' : 'Bem-vindo de volta',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 22),
                  if (register) ...[
                    TextFormField(
                      controller: nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                          labelText: 'Nome',
                          prefixIcon: Icon(Icons.person_outline)),
                      validator: (value) => (value == null ||
                              value.trim().length < 3 ||
                              value.trim().length > 100)
                          ? 'Informe seu nome (entre 3 e 100 caracteres).'
                          : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'E-mail',
                        prefixIcon: Icon(Icons.email_outlined)),
                    validator: (value) => value == null ||
                            !RegExp(
                              r"^[^@\s]+@[^@\s]+\.[^@\s]+$",
                            ).hasMatch(value.trim())
                        ? 'Informe um e-mail válido.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => obscurePassword = !obscurePassword),
                        icon: Icon(obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                      ),
                    ),
                    validator: (value) => value == null || value.length < 8
                        ? 'A senha deve ter pelo menos 8 caracteres.'
                        : null,
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: submitting ? null : _submit,
                    child: submitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(register ? 'Criar conta' : 'Entrar'),
                  ),
                  TextButton(
                    onPressed: submitting
                        ? null
                        : () => setState(() => register = !register),
                    child: Text(register
                        ? 'Já tenho uma conta'
                        : 'Ainda não tenho conta'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> _submit() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => submitting = true);
    try {
      await widget.app.authenticate(
        email: emailController.text.trim(),
        password: passwordController.text,
        name: register ? nameController.text.trim() : null,
      );
      if (mounted) Navigator.pop(context);
    } on ApiException catch (error) {
      if (mounted) showError(context, error.message);
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class GameCover extends StatelessWidget {
  const GameCover(
      {super.key,
      required this.url,
      required this.width,
      required this.height});

  final String? url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final image = url?.trim() ?? '';
    if (image.isEmpty) {
      return Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(
          Icons.videogame_asset_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Image.network(
      image,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(
          Icons.broken_image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
        child: Column(
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 42,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 40, color: Colors.orangeAccent),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style: emphasized
                    ? Theme.of(context).textTheme.titleMedium
                    : Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: emphasized
                  ? Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)
                  : Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ],
        ),
      );
}

ThemeData _playceTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: purple,
    brightness: brightness,
    surface: isDark ? cardBackground : Colors.white,
  );
  return ThemeData(
    brightness: brightness,
    colorScheme: colors,
    scaffoldBackgroundColor: isDark ? darkBackground : const Color(0xFFF8F9FA),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? darkBackground : const Color(0xFFF8F9FA),
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? cardBackground : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}

String currency(double amount) =>
    'R\$ ${amount.toStringAsFixed(2).replaceAll('.', ',')}';

String formatDate(DateTime date) {
  final local = date.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  return '$day/$month/${local.year}';
}

int _asInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red.shade800),
  );
}

Map<String, dynamic> _decodeSession(String value) {
  final decoded = jsonDecode(value);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('Sessão inválida');
}

String _encodeSession(Map<String, dynamic> value) => jsonEncode(value);
