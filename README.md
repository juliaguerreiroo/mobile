## Nomes

- Julia Dalanora Guerreiro
- Edson Werner Civa

# Playce Mobile

Aplicativo Flutter da loja Playce. Consome a mesma API NestJS e o mesmo banco
utilizados pela versão web.

## Funcionalidades

- Loja com promoções, busca, filtros por categoria e detalhes dos jogos.
- Cadastro, login, sessão persistida e carrinho local.
- Checkout demonstrativo, confirmação com o valor calculado pelo backend e
  histórico de compras.
- Planos, jogos vinculados, faixa de descontos, confirmação e renovação de
  assinatura por 30 dias.
- Biblioteca com jogos comprados e acesso temporário do plano; o download é
  simulado pelo backend e atualiza o tempo jogado.
- Tema claro/escuro.

O backend é a fonte de verdade para compras, descontos, duplicidade, acesso e
datas das assinaturas. O checkout exibe Pix apenas como demonstração: não há
processamento ou cobrança real. As telas administrativas e de publicação de
jogos não fazem parte deste app.

## Preparar o projeto

Requer Flutter 3.50 ou superior. Os projetos Android, iOS e web já estão
incluídos. Na pasta `playce_mobile`, instale as dependências:

```bash
flutter pub get
```

Na primeira configuração do backend, use as instruções de
[`LEIA-ME.txt`](../LEIA-ME.txt) para carregar o banco de demonstração e configure
`DATABASE_URL="file:./dev.db"`. Inicie a API na porta `3000`, depois execute o
app:

```bash
flutter run
```

O endereço padrão da API é `http://10.0.2.2:3000/api`, apropriado para o
emulador Android. Para iOS Simulator, use `http://localhost:3000/api`. Em um
aparelho físico, informe o IP da máquina que executa o backend na mesma rede:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.0.10:3000/api
```

Substitua o IP pelo endereço local da máquina. O backend precisa aceitar
conexões nessa interface de rede; `localhost` no aparelho aponta para o próprio
aparelho, não para o computador.

Para desenvolvimento local com HTTP, permita tráfego não criptografado apenas
no ambiente de desenvolvimento. O projeto já habilita HTTP no manifesto
Android de debug; builds de release devem usar HTTPS. No iOS, o projeto permite
acesso de rede local para o servidor de desenvolvimento. Use HTTPS ao publicar.

Para gerar um APK de debug com o emulador Android configurado:

```bash
flutter build apk --debug
```

## Validar

```bash
dart format lib test
flutter analyze
flutter test
```
