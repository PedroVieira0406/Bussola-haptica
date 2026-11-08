// ============================================================================
// ANCORA BLE - No Ancora (BLE Peripheral / GATT Server) - TCC
// Sistema de navegacao assistiva para pessoas com surdocegueira.
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
// Protocolo BLE (deve ser identico ao firmware do ESP32-S3)
// ---------------------------------------------------------------------------
const String kServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String kCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

// Intervalo entre PINGs (1 segundo).
const Duration kPingInterval = Duration(seconds: 1);

// ---------------------------------------------------------------------------
// Paleta: modo escuro (padrao) e modo claro. Edite as cores aqui.
// ---------------------------------------------------------------------------
class AppColors {
  final Color bg, card, border, text, muted, cyan, amber, green, red;
  const AppColors({
    required this.bg,
    required this.card,
    required this.border,
    required this.text,
    required this.muted,
    required this.cyan,
    required this.amber,
    required this.green,
    required this.red,
  });

  // Escuro, alto contraste
  static const AppColors dark = AppColors(
    bg: Color(0xFF0A0C10),
    card: Color(0xFF141821),
    border: Color(0xFF262D3B),
    text: Color(0xFFF2F5FA),
    muted: Color(0xFF8A94A8),
    cyan: Color(0xFF22D3EE),
    amber: Color(0xFFFBBF24),
    green: Color(0xFF34D399),
    red: Color(0xFFF87171),
  );

  // Claro: cores de destaque mais escuras para manter o contraste sobre o branco
  static const AppColors light = AppColors(
    bg: Color(0xFFF4F6FA),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFD5DBE6),
    text: Color(0xFF111827),
    muted: Color(0xFF5B6475),
    cyan: Color(0xFF0E7490),
    amber: Color(0xFFB45309),
    green: Color(0xFF047857),
    red: Color(0xFFB91C1C),
  );
}

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
// Controlador (estado + logica BLE)
// ---------------------------------------------------------------------------
enum AnchorStatus { inactive, advertising, connected }

class AnchorController extends ChangeNotifier {
  AnchorStatus status = AnchorStatus.inactive;
  bool busy = false;
  String? error;

  // Telemetria vinda do ESP32-S3
  double? distance;
  double? rssi;
  double? accX, accY, accZ;
  double? gyroX, gyroY, gyroZ;
  int packetsReceived = 0;
  int pingsSent = 0;
  DateTime? lastUpdate;

  Timer? _pulseTimer;
  bool _initialized = false;
  bool _serviceAdded = false;
  bool _active = false;
  bool _subscribed = false;
  bool _deviceConnected = false;

  bool get isActive => _active;

  // ----- Permissoes -------------------------------------------------------
  Future<bool> _requestPermissions() async {
    final result = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.notification,
    ].request();

    final ok = (result[Permission.bluetoothAdvertise]?.isGranted ?? false) &&
        (result[Permission.bluetoothConnect]?.isGranted ?? false);
    if (!ok) {
      error = 'Permissoes Bluetooth negadas. Habilite em Configuracoes.';
    }
    return ok;
  }

  // ----- Inicializacao do GATT Server (uma unica vez) ---------------------
  Future<void> _ensureGattServer() async {
    if (!_initialized) {
      await BlePeripheral.initialize();

      BlePeripheral.setAdvertisingStatusUpdateCallback(
            (bool advertising, String? err) {
          // Ignora erro 3 (ADVERTISE_FAILED_ALREADY_STARTED) caso ocorra
          if (err != null && !err.contains('3')) {
            error = 'Advertising: $err';
          } else if (_active && !_subscribed && !_deviceConnected && advertising) {
            status = AnchorStatus.advertising;
          }
          notifyListeners();
        },
      );

      BlePeripheral.setConnectionStateChangeCallback(
            (String deviceId, bool connected) {
          _deviceConnected = connected;
          if (connected) {
            if (_active) {
              status = AnchorStatus.connected;
            }
          } else {
            _subscribed = false;
            if (_active) {
              status = AnchorStatus.advertising;
              // Reinicia o anuncio de forma limpa apos desconexao
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
              if (_active) {
                status = AnchorStatus.connected;
                _sendPing(); // Envia o primeiro PING imediatamente ao assinar
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

      // OnWrite: o ESP32-S3 devolve o CSV aqui.
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
                CharacteristicProperties.indicate.index,
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
      notifyListeners();
    }
  }

  // ----- Foreground Service ----------------------------------------------
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ancora_ble_channel',
        channelName: 'Ancora BLE',
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
        notificationTitle: 'Ancora BLE ativa',
        notificationText: 'Anunciando e aguardando o ESP32-S3 (Bussola).',
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

    await _startAdvertising();

    if (_deviceConnected || _subscribed) {
      status = AnchorStatus.connected;
    } else {
      status = AnchorStatus.advertising;
    }

    _pulseTimer?.cancel();
    _pulseTimer = Timer.periodic(kPingInterval, (_) => _sendPing());
  }

  /// Envia "STOP" para a Bussola encerrar a sessao e chamar disconnect()
  Future<void> _requestDisconnect() async {
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
    notifyListeners();
  }

  Future<void> _sendPing() async {
    // Permite enviar PING se estiver inscrito OU se o dispositivo ja estiver conectado
    if (!_active || (!_subscribed && !_deviceConnected)) return;
    try {
      final nextPing = pingsSent + 1;
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
    if (parts.length < 8) return;

    final v = parts.take(8).map((e) => double.tryParse(e.trim())).toList();
    if (v.any((e) => e == null)) return;

    final eraPrimeiroPacote = !_subscribed;

    distance = v[0];
    rssi = v[1];
    accX = v[2];
    accY = v[3];
    accZ = v[4];
    gyroX = v[5];
    gyroY = v[6];
    gyroZ = v[7];
    packetsReceived++;
    lastUpdate = DateTime.now();

    _deviceConnected = true;
    _subscribed = true;
    if (status != AnchorStatus.connected) {
      status = AnchorStatus.connected;
    }
    notifyListeners();

    // Se acabou de receber o handshake inicial do ESP32, responde com PING imediato
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
void aplicarBarrasDoSistema(AppColors p, bool claro) {
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    statusBarIconBrightness: claro ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: p.bg,
    systemNavigationBarIconBrightness:
    claro ? Brightness.dark : Brightness.light,
  ));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  aplicarBarrasDoSistema(AppColors.dark, false);
  runApp(const AncoraApp());
}

class AncoraApp extends StatelessWidget {
  const AncoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: AppColors.dark.bg,
      debugShowCheckedModeBanner: false,
      textStyle: TextStyle(
        color: AppColors.dark.text,
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
// Tela unica
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
  bool _claro = false;
  AppColors get _p => _claro ? AppColors.light : AppColors.dark;

  void _alternarTema() {
    setState(() => _claro = !_claro);
    aplicarBarrasDoSistema(_p, _claro);
  }

  void _onPowerTap() {
    if (_c.busy) return;
    if (_c.isActive) {
      setState(() => _confirmando = true);
    } else {
      _c.toggle();
    }
  }

  void _cancelarDesconexao() {
    if (_confirmando) setState(() => _confirmando = false);
  }

  void _confirmarDesconexao() {
    setState(() => _confirmando = false);
    _c.toggle();
  }

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

  String _fmt(double? v, int d) => v == null ? '--' : v.toStringAsFixed(d);

  String _time(DateTime? t) {
    if (t == null) return '--:--:--';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return DefaultTextStyle(
      style: TextStyle(
        color: p.text,
        fontSize: 14,
        fontFamily: 'monospace',
        decoration: TextDecoration.none,
      ),
      child: Container(
        color: p.bg,
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
                  DateTime.now().difference(_c.lastUpdate!).inSeconds > 3);

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 14),
                _statusPill(),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _bigCard(
                        label: 'DISTANCIA',
                        value: _fmt(_c.distance, 2),
                        unit: 'm',
                        color: _p.cyan,
                        dim: stale,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _bigCard(
                        label: 'RSSI SUAVIZADO',
                        value: _fmt(_c.rssi, 1),
                        unit: 'dBm',
                        color: _p.amber,
                        dim: stale,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _imuPanel(stale),
                const SizedBox(height: 12),
                _statsRow(stale),
                if (_c.error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _c.error!,
                    style: TextStyle(color: _p.red, fontSize: 12),
                  ),
                ],
                const Spacer(),
                _powerButton(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _confirmOverlay() {
    final p = _p;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _cancelarDesconexao,
        child: Container(
          color: _claro ? const Color(0x99000000) : const Color(0xCC000000),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.red, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'DESCONECTAR A BUSSOLA?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: p.red,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Deseja mesmo desconectar a bussola do celular? '
                        'O envio de dados sera interrompido.',
                    style: TextStyle(fontSize: 14, color: p.text, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _cancelarDesconexao,
                          child: Container(
                            height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: p.muted.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: p.muted, width: 2),
                            ),
                            child: Text(
                              'CANCELAR',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                                color: p.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _confirmarDesconexao,
                          child: Container(
                            height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: p.red.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: p.red, width: 2),
                            ),
                            child: Text(
                              'DESCONECTAR',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                                color: p.red,
                              ),
                            ),
                          ),
                        ),
                      ),
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

  Widget _header() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ANCORA BLE',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                ),
              ),
              Text(
                'GATT SERVER',
                style: TextStyle(
                    fontSize: 11, color: _p.muted, letterSpacing: 2),
              ),
            ],
          ),
        ),
        _themeButton(),
      ],
    );
  }

  Widget _themeButton() {
    final cor = _p.amber;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _alternarTema,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cor, width: 1.5),
        ),
        child: Text(
          _claro ? 'MODO ESCURO' : 'MODO CLARO',
          style: TextStyle(
            color: cor,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final p = _p;
    late final Color color;
    late final String label;
    switch (_c.status) {
      case AnchorStatus.inactive:
        color = p.muted;
        label = 'INATIVA';
        break;
      case AnchorStatus.advertising:
        color = p.amber;
        label = 'ANUNCIANDO BLE...';
        break;
      case AnchorStatus.connected:
        color = p.green;
        label = 'ESP32 BUSSOLA CONECTADO';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: p.card,
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

  Widget _bigCard({
    required String label,
    required String value,
    required String unit,
    required Color color,
    required bool dim,
  }) {
    final p = _p;
    final c = dim ? color.withOpacity(0.35) : color;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
              TextStyle(fontSize: 10, color: p.muted, letterSpacing: 1.5)),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              color: c,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(unit, style: TextStyle(fontSize: 13, color: p.muted)),
        ],
      ),
    );
  }

  Widget _imuPanel(bool stale) {
    final p = _p;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MPU-6050',
              style: TextStyle(fontSize: 11, color: p.muted, letterSpacing: 2)),
          const SizedBox(height: 12),
          Text('ACELEROMETRO (g)',
              style: TextStyle(fontSize: 10, color: p.cyan, letterSpacing: 1)),
          const SizedBox(height: 6),
          Row(children: [
            _axis('AccX', _fmt(_c.accX, 2), stale),
            _axis('AccY', _fmt(_c.accY, 2), stale),
            _axis('AccZ', _fmt(_c.accZ, 2), stale),
          ]),
          const SizedBox(height: 14),
          Text('GIROSCOPIO (°/s)',
              style: TextStyle(fontSize: 10, color: p.amber, letterSpacing: 1)),
          const SizedBox(height: 6),
          Row(children: [
            _axis('GyroX', _fmt(_c.gyroX, 2), stale),
            _axis('GyroY', _fmt(_c.gyroY, 2), stale),
            _axis('GyroZ', _fmt(_c.gyroZ, 2), stale),
          ]),
        ],
      ),
    );
  }

  Widget _axis(String label, String value, bool stale) {
    final p = _p;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: p.muted)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: stale ? p.muted : p.text,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsRow(bool stale) {
    final p = _p;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          _stat('PACOTES RX', '${_c.packetsReceived}', p.text),
          _stat('PINGS TX', '${_c.pingsSent}', p.text),
          _stat('ULTIMA ATUALIZ.', _time(_c.lastUpdate),
              stale ? p.red : p.green),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 9, color: _p.muted, letterSpacing: 1)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _powerButton() {
    final p = _p;
    final on = _c.isActive;
    final color = on ? p.red : p.green;
    final label = _c.busy
        ? 'AGUARDE...'
        : (on ? 'DESATIVAR ANCORA' : 'ATIVAR ANCORA');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onPowerTap,
      child: Container(
        height: 76,
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
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}