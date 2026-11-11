// ============================================================================
// ANCORA HAPTICA - No Ancora (BLE Peripheral / GATT Server) + Painel + Terminal
// TCC - Sistema de navegacao assistiva P2P para pessoas com surdocegueira.
//
// Interface minimalista: so Container/Stack/Column/Row/Text, sem Scaffold,
// AppBar, Material ou animacoes. Somente Dark Mode.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

// ---------------------------------------------------------------------------
// Protocolo BLE (identico ao firmware do ESP32-S3)
// ---------------------------------------------------------------------------
const String kServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String kCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

const Duration kSyncInterval = Duration(seconds: 1); // PING (sincronismo)

// ---------------------------------------------------------------------------
// Paleta (somente escuro, alto contraste)
// ---------------------------------------------------------------------------
const Color kBg = Color(0xFF0A0C10);
const Color kCard = Color(0xFF141821);
const Color kBorder = Color(0xFF262D3B);
const Color kText = Color(0xFFF2F5FA);
const Color kMuted = Color(0xFF8A94A8);
const Color kCyan = Color(0xFF22D3EE);
const Color kAmber = Color(0xFFFBBF24);
const Color kGreen = Color(0xFF34D399);
const Color kRed = Color(0xFFF87171);

// ---------------------------------------------------------------------------
// Foreground Service (mantem o radio BLE vivo com a tela bloqueada)
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_AnchorTaskHandler());
}

class _AnchorTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// ---------------------------------------------------------------------------
// Controlador (estado + logica BLE GATT Server + Terminal da Bussola)
// ---------------------------------------------------------------------------
enum AnchorStatus { inactive, advertising, connected }

class AnchorController extends ChangeNotifier {
  AnchorStatus status = AnchorStatus.inactive;
  bool busy = false;
  String? error;

  // Telemetria vinda do ESP32-S3
  double? distance; // metros
  double? rssi; // dBm
  double? accX, accY, accZ;
  double? gyroX, gyroY, gyroZ;
  int packetsReceived = 0;
  int pingsSent = 0;
  int pongsReceived = 0;
  int? lastRttMs;
  DateTime? lastUpdate;

  // Historico do Terminal da Bussola
  final List<String> logs = [];
  static const int _maxLogs = 40;

  final Map<int, DateTime> _pingSentAt = {};
  Timer? _pulseTimer;
  bool _initialized = false;
  bool _serviceAdded = false;
  bool _active = false;
  bool _subscribed = false;
  bool _deviceConnected = false;

  bool get isActive => _active;

  void _addLog(String msg) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    logs.insert(0, '[$ts] $msg');
    if (logs.length > _maxLogs) {
      logs.removeRange(_maxLogs, logs.length);
    }
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  // ----- Permissoes (Android 12+) -----------------------------------------
  Future<bool> _requestPermissions() async {
    final result = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.notification,
    ].request();

    final ok = (result[Permission.bluetoothAdvertise]?.isGranted ?? false) &&
        (result[Permission.bluetoothConnect]?.isGranted ?? false);
    if (!ok) {
      error = 'Permissoes Bluetooth negadas. Habilite em Configuracoes.';
      _addLog('ERRO: Permissoes Bluetooth negadas.');
    }
    return ok;
  }

  // ----- Inicializacao do GATT Server (uma unica vez) ---------------------
  Future<void> _ensureGattServer() async {
    if (!_initialized) {
      await BlePeripheral.initialize();

      BlePeripheral.setAdvertisingStatusUpdateCallback(
            (bool advertising, String? err) {
          if (err != null && !err.contains('3')) {
            error = 'Advertising: $err';
            _addLog('ERRO ADV: $err');
          } else if (_active && !_subscribed && !_deviceConnected && advertising) {
            status = AnchorStatus.advertising;
            _addLog('Anunciando servico BLE...');
          }
          notifyListeners();
        },
      );

      BlePeripheral.setConnectionStateChangeCallback(
            (String deviceId, bool connected) {
          _deviceConnected = connected;
          if (connected) {
            _addLog('Bussola conectada ($deviceId)');
            if (_active) {
              status = AnchorStatus.connected;
            }
          } else {
            _subscribed = false;
            _addLog('Bussola desconectada ($deviceId)');
            if (_active) {
              status = AnchorStatus.advertising;
              _startAdvertising();
            }
          }
          notifyListeners();
        },
      );

      BlePeripheral.setCharacteristicSubscriptionChangeCallback(
            (String deviceId, String characteristicId, bool isSubscribed,
            String? name) {
          if (characteristicId.toLowerCase() ==
              kCharacteristicUuid.toLowerCase()) {
            _subscribed = isSubscribed;
            if (isSubscribed) {
              _deviceConnected = true;
              _addLog('Notificacoes assinadas pela Bussola');
              if (_active) {
                status = AnchorStatus.connected;
                _sendPing();
              }
            } else {
              if (_active && !_deviceConnected) {
                status = AnchorStatus.advertising;
              }
            }
            notifyListeners();
          }
        },
      );

      // WRITE: o ESP32-S3 devolve o CSV aqui (PONG e telemetria periodica).
      BlePeripheral.setWriteRequestCallback(
            (String deviceId, String characteristicId, int offset,
            Uint8List? value) {
          if (_active && value != null) {
            _handlePayload(value);
          }
          return null;
        },
      );

      BlePeripheral.setReadRequestCallback(
            (String deviceId, String characteristicId, int offset,
            Uint8List? value) {
          return ReadRequestResult(
            value: Uint8List.fromList(utf8.encode('ANCORA')),
          );
        },
      );

      _initialized = true;
    }

    if (!_serviceAdded) {
      await BlePeripheral.addService(
        BleService(
          uuid: kServiceUuid,
          primary: true,
          characteristics: [
            BleCharacteristic(
              uuid: kCharacteristicUuid,
              properties: [
                CharacteristicProperties.read.index,
                CharacteristicProperties.write.index,
                CharacteristicProperties.writeWithoutResponse.index,
                CharacteristicProperties.notify.index,
              ],
              permissions: [
                AttributePermissions.readable.index,
                AttributePermissions.writeable.index,
              ],
              value: null,
            ),
          ],
        ),
      );
      _serviceAdded = true;
    }
  }

  Future<void> _startAdvertising() async {
    if (!_active) return;
    try {
      try {
        await BlePeripheral.stopAdvertising();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));

      if (!_active) return;
      await BlePeripheral.startAdvertising(
        services: [kServiceUuid],
      );
    } catch (e) {
      error = 'Falha ao anunciar: $e';
      _addLog('Falha ao anunciar: $e');
      notifyListeners();
    }
  }

  // ----- Foreground Service ----------------------------------------------
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ancora_ble_channel',
        channelName: 'Ancora Haptica',
        channelDescription: 'Mantem a Ancora BLE ativa em segundo plano.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _startForeground() async {
    _initForegroundTask();
    try {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 7001,
        notificationTitle: 'Âncora Háptica Ativa',
        notificationText: 'Anunciando sinal BLE para a Bússola.',
        callback: startCallback,
      );
    }
  }

  // ----- Liga / Desliga ---------------------------------------------------
  Future<void> toggle() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (_active) {
        await _stop();
      } else {
        await _start();
      }
    } catch (e) {
      error = 'Erro: $e';
      _addLog('Erro: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _start() async {
    if (!await _requestPermissions()) return;
    await _startForeground();
    await _ensureGattServer();

    _active = true;
    packetsReceived = 0;
    pingsSent = 0;
    pongsReceived = 0;
    lastRttMs = null;
    _pingSentAt.clear();
    _addLog('Ancora iniciada.');

    await _startAdvertising();

    if (_deviceConnected || _subscribed) {
      status = AnchorStatus.connected;
    } else {
      status = AnchorStatus.advertising;
    }

    _pulseTimer?.cancel();
    _pulseTimer = Timer.periodic(kSyncInterval, (_) => _sendPing());
  }

  Future<void> _requestDisconnect() async {
    _addLog('Enviando comando STOP para a Bussola...');
    for (var tentativa = 0;
    tentativa < 4 && (_deviceConnected || _subscribed);
    tentativa++) {
      try {
        await BlePeripheral.updateCharacteristic(
          characteristicId: kCharacteristicUuid,
          value: Uint8List.fromList(utf8.encode('STOP')),
        );
      } catch (_) {}

      for (var t = 0; t < 14 && (_deviceConnected || _subscribed); t++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _stop() async {
    _active = false;
    _pulseTimer?.cancel();
    _pulseTimer = null;

    if (_deviceConnected || _subscribed) {
      await _requestDisconnect();
    }

    _subscribed = false;
    _deviceConnected = false;

    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}

    status = AnchorStatus.inactive;
    _addLog('Ancora desligada.');
    notifyListeners();
  }

  Future<void> _sendPing() async {
    if (!_active || (!_subscribed && !_deviceConnected)) return;
    try {
      final nextPing = pingsSent + 1;
      _pingSentAt[nextPing] = DateTime.now();
      if (_pingSentAt.length > 20) {
        _pingSentAt.remove(_pingSentAt.keys.first);
      }
      await BlePeripheral.updateCharacteristic(
        characteristicId: kCharacteristicUuid,
        value: Uint8List.fromList(utf8.encode('PING:$nextPing')),
      );
      pingsSent = nextPing;
      error = null;
      notifyListeners();
    } catch (_) {}
  }

  // ----- Parse do CSV -----------------------------------------------------
  void _handlePayload(Uint8List bytes) {
    if (!_active) return;

    final text = utf8.decode(bytes, allowMalformed: true).trim();
    final parts = text.split(',');
    if (parts.length < 8) {
      _addLog('RX bruto: $text');
      notifyListeners();
      return;
    }

    final v = parts.take(8).map((e) => double.tryParse(e.trim())).toList();
    if (v.any((e) => e == null)) return;

    final eraPrimeiroPacote = !_subscribed;

    distance = v[0];
    rssi = v[1]! > 0 ? v[1]! - 100.0 : v[1];
    accX = v[2];
    accY = v[3];
    accZ = v[4];
    gyroX = v[5];
    gyroY = v[6];
    gyroZ = v[7];
    packetsReceived++;
    lastUpdate = DateTime.now();

    int pingId = 0;
    if (parts.length >= 9) {
      pingId = int.tryParse(parts[8].trim()) ?? 0;
      if (pingId > 0) {
        final t = _pingSentAt.remove(pingId);
        if (t != null) {
          lastRttMs = DateTime.now().difference(t).inMilliseconds;
          pongsReceived++;
        }
      }
    }

    final tag = pingId > 0 ? 'PONG #$pingId' : 'TX #$packetsReceived';
    _addLog('$tag | d=${distance!.toStringAsFixed(2)}m | '
        'rssi=${rssi!.toStringAsFixed(0)}dBm | CSV: $text');

    _deviceConnected = true;
    _subscribed = true;
    if (status != AnchorStatus.connected) {
      status = AnchorStatus.connected;
    }
    notifyListeners();

    if (eraPrimeiroPacote) {
      _sendPing();
    }
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: kBg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const AncoraApp());
}

class AncoraApp extends StatelessWidget {
  const AncoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: kBg,
      debugShowCheckedModeBanner: false,
      textStyle: const TextStyle(
        color: kText,
        fontSize: 14,
        fontFamily: 'monospace',
        decoration: TextDecoration.none,
      ),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
        return PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, __) => builder(context),
        );
      },
      home: const DashboardPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela unica (apenas Container / Stack / Column / Row / Text)
// ---------------------------------------------------------------------------
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final AnchorController _c = AnchorController();
  Timer? _clock;
  bool _confirmando = false;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _c.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _onPowerTap() {
    if (_c.busy) return;
    if (_c.isActive) {
      setState(() => _confirmando = true);
    } else {
      _c.toggle();
    }
  }

  void _cancelar() {
    if (_confirmando) setState(() => _confirmando = false);
  }

  void _confirmar() {
    setState(() => _confirmando = false);
    _c.toggle();
  }

  String _fmt(double? v, int d) => v == null ? '--' : v.toStringAsFixed(d);

  String _time(DateTime? t) {
    if (t == null) return '--:--:--';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: const TextStyle(
        color: kText,
        fontSize: 14,
        fontFamily: 'monospace',
        decoration: TextDecoration.none,
      ),
      child: Container(
        color: kBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _conteudo(),
            if (_confirmando) _confirmOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _conteudo() {
    return SafeArea(
      child: ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final stale = !_c.isActive ||
              (_c.lastUpdate != null &&
                  DateTime.now().difference(_c.lastUpdate!).inMilliseconds >
                      3000);

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 10),
                _statusPill(),
                const SizedBox(height: 10),
                _cardDistRssi(stale),
                const SizedBox(height: 10),
                _cardEixos(
                  titulo: 'ACELEROMETRO (g)',
                  cor: kCyan,
                  x: _c.accX,
                  y: _c.accY,
                  z: _c.accZ,
                  stale: stale,
                ),
                const SizedBox(height: 10),
                _cardEixos(
                  titulo: 'GIROSCOPIO (°/s)',
                  cor: kAmber,
                  x: _c.gyroX,
                  y: _c.gyroY,
                  z: _c.gyroZ,
                  stale: stale,
                ),
                const SizedBox(height: 8),
                _rodape(stale),
                if (_c.error != null) ...[
                  const SizedBox(height: 6),
                  Text(_c.error!,
                      style: const TextStyle(color: kRed, fontSize: 12)),
                ],
                const SizedBox(height: 10),
                Expanded(child: _cardTerminal()),
                const SizedBox(height: 10),
                _powerButton(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'ANCORA HAPTICA',
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 3),
        ),
        Text(
          'GATT SERVER  |  TELEMETRIA',
          style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 2),
        ),
      ],
    );
  }

  Widget _statusPill() {
    late final Color color;
    late final String label;
    switch (_c.status) {
      case AnchorStatus.inactive:
        color = kMuted;
        label = 'DESLIGADO';
        break;
      case AnchorStatus.advertising:
        color = kAmber;
        label = 'ANUNCIANDO SINAL...';
        break;
      case AnchorStatus.connected:
        color = kGreen;
        label = 'CONECTADO';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardDistRssi(bool stale) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDeco(),
      child: Row(
        children: [
          _big('DISTANCIA', _fmt(_c.distance, 2), 'm', kCyan, stale),
          _big('RSSI', _fmt(_c.rssi, 1), 'dBm', kAmber, stale),
        ],
      ),
    );
  }

  Widget _big(String label, String value, String unit, Color cor, bool stale) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: kMuted, letterSpacing: 1.5)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: stale ? cor.withOpacity(0.35) : cor,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(unit, style: const TextStyle(fontSize: 12, color: kMuted)),
        ],
      ),
    );
  }

  Widget _cardEixos({
    required String titulo,
    required Color cor,
    required double? x,
    required double? y,
    required double? z,
    required bool stale,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDeco(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo,
              style: TextStyle(fontSize: 11, color: cor, letterSpacing: 1.5)),
          const SizedBox(height: 6),
          Row(
            children: [
              _axis('X', _fmt(x, 2), stale),
              _axis('Y', _fmt(y, 2), stale),
              _axis('Z', _fmt(z, 2), stale),
            ],
          ),
        ],
      ),
    );
  }

  Widget _axis(String label, String value, bool stale) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: kMuted)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: stale ? kMuted : kText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rodape(bool stale) {
    final rtt = _c.lastRttMs == null ? '--' : '${_c.lastRttMs}ms';
    return Text(
      'RX ${_c.packetsReceived}  PING ${_c.pingsSent}  PONG ${_c.pongsReceived}'
          '  RTT $rtt  ${_time(_c.lastUpdate)}',
      style: TextStyle(fontSize: 11, color: stale ? kRed : kMuted),
    );
  }

  // Painel do Terminal da Bussola
  Widget _cardTerminal() {
    final linhas = _c.logs.take(10).toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDeco(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'TERMINAL DA BUSSOLA',
                style: TextStyle(
                  fontSize: 11,
                  color: kGreen,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _c.clearLogs,
                child: const Text(
                  'LIMPAR',
                  style: TextStyle(
                    fontSize: 10,
                    color: kMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: linhas.isEmpty
                ? const Text(
              'Aguardando pacotes da Bussola...',
              style: TextStyle(fontSize: 11, color: kMuted),
            )
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in linhas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      l,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: kText,
                        height: 1.2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _cardDeco() => BoxDecoration(
    color: kCard,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: kBorder),
  );

  Widget _powerButton() {
    final on = _c.isActive;
    final color = on ? kRed : kGreen;
    final label = _c.busy
        ? 'AGUARDE...'
        : (on ? 'DESATIVAR ANCORA' : 'ATIVAR ANCORA');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onPowerTap,
      child: Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color, width: 2.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }

  Widget _confirmOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _cancelar,
        child: Container(
          color: const Color(0xCC000000),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kRed, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'DESATIVAR A ANCORA?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: kRed,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A Bussola sera desconectada e o envio de dados '
                        'sera interrompido.',
                    style: TextStyle(fontSize: 14, color: kText, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                          child: _botaoOverlay('CANCELAR', kMuted, _cancelar)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: _botaoOverlay('DESATIVAR', kRed, _confirmar)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _botaoOverlay(String texto, Color cor, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cor.withOpacity(0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cor, width: 2),
        ),
        child: Text(
          texto,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: cor == kMuted ? kText : cor,
          ),
        ),
      ),
    );
  }
}