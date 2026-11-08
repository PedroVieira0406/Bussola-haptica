/*
 * ======================================================================
 *  BUSSOLA - Cliente BLE + Alcance Maximo (+9 dBm) + Distancia + MPU6050
 *  v5.8: Potencia Maxima de RF (Conecta de Longe) + LEDs (11=Vd, 12=Vm, 13=Am)
 * ======================================================================
 */

#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Wire.h>
#include <nvs_flash.h>

// Header nativo da Espressif para destravar a potencia maxima (+9 dBm) do radio
#if __has_include("esp_bt.h")
  #include "esp_bt.h"
#endif

enum EstadoLed { LED_AGUARDANDO, LED_CONECTADO, LED_DESCONECTADO };

// ======================================================================
//  PAINEL DE AJUSTES
// ======================================================================

#define FW_VERSAO "v5.8-max-range"

// 1) ESCOLHA COMO EXIBIR O VALOR REAL NO APP:
// true  = Envia os dB reais acima do piso de ruido (-100 dBm):
//         Perto = ~60.0 dB | 1 metro = ~41.0 dB | Longe = ~15.0 dB (DIMINUI AO AFASTAR!)
// false = Envia o RSSI negativo puro (-40.0 dBm perto -> -85.0 dBm longe)
const bool MOSTRAR_EM_DB_POSITIVO = true;

// RSSI real medido a 1 metro de distancia (em dBm negativos)
const float RSSI_A_1_METRO = -59.0;
const float PATH_LOSS_N    = 2.5;
const int   RSSI_JANELA    = 8;

float calcularDistancia(float rssiDbm) {
  float rssiNeg = (rssiDbm > 0) ? -rssiDbm : rssiDbm;
  float expoente = (RSSI_A_1_METRO - rssiNeg) / (10.0 * PATH_LOSS_N);
  float dist = pow(10.0, expoente);

  if (dist < 0.05) dist = 0.05;
  if (dist > 50.0) dist = 50.0;
  return dist;
}

// 2) LEDs DE STATUS (Mapeamento fisico real da bancada)
//    Pino 11 = Verde | Pino 12 = Vermelho | Pino 13 = Amarelo
const uint8_t PIN_LED_VERDE    = 11;
const uint8_t PIN_LED_VERMELHO = 12;
const uint8_t PIN_LED_AMARELO  = 13;

const bool LED_ATIVO_EM_HIGH = true;
const bool LED_TESTE_NA_INICIALIZACAO = true;
const unsigned long LED_VERMELHO_TEMPO_MS = 3000;
const bool LED_VERMELHO_ATE_RECONECTAR = false;

// 3) TEMPOS DA SESSAO (LIMITADOR DE 5 SEGUNDOS)
const unsigned long INTERVALO_ENVIO_MS     = 300;  // Envia telemetria a cada 300ms
const unsigned long TIMEOUT_DESCONEXAO_MS  = 5000; // So desconecta apos 5 segundos (5000ms) sem resposta
const unsigned long COOLDOWN_APOS_STOP_MS  = 2000;

// ======================================================================
//  FIM DO PAINEL DE AJUSTES
// ======================================================================

static BLEUUID serviceUUID("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
static BLEUUID charUUID("beb5483e-36e1-4688-b7f5-ea07361b26a8");
static BLEUUID cccdUUID((uint16_t)0x2902);

static volatile boolean doConnect = false;
static volatile boolean connected = false;
static BLERemoteCharacteristic* pRemoteCharacteristic = nullptr;
static BLEAdvertisedDevice* myDevice = nullptr;
static BLEClient* pClient = nullptr;

static volatile bool desconectarSolicitado = false;
static volatile unsigned long ultimaAtividadeMs = 0;
static volatile unsigned long quedaFisicaInicioMs = 0;
static volatile long ultimoPingIdRecebido = 0;
static unsigned long ultimoEnvioMs = 0;
static uint32_t pacotesEnviados = 0;

static volatile bool sessaoEncerrada = false;
static volatile unsigned long bloqueioScanAteMs = 0;

// ----------------------------------------------------------------------
// LEDs - logica de estado
// ----------------------------------------------------------------------
static volatile unsigned long ledVermelhoAteMs = 0;
static volatile bool houveDesconexao = false;

static void ledEscrever(uint8_t pino, bool ligado) {
  digitalWrite(pino, (ligado == LED_ATIVO_EM_HIGH) ? HIGH : LOW);
}

static void ledsMostrar(EstadoLed e) {
  ledEscrever(PIN_LED_VERDE,    e == LED_CONECTADO);
  ledEscrever(PIN_LED_VERMELHO, e == LED_DESCONECTADO);
  ledEscrever(PIN_LED_AMARELO,  e == LED_AGUARDANDO);
}

static void ledsIniciar() {
  pinMode(PIN_LED_VERDE, OUTPUT);
  pinMode(PIN_LED_VERMELHO, OUTPUT);
  pinMode(PIN_LED_AMARELO, OUTPUT);

  ledEscrever(PIN_LED_VERDE, false);
  ledEscrever(PIN_LED_VERMELHO, false);
  ledEscrever(PIN_LED_AMARELO, false);

  if (LED_TESTE_NA_INICIALIZACAO) {
    ledsMostrar(LED_CONECTADO);    delay(300);
    ledsMostrar(LED_AGUARDANDO);   delay(300);
    ledsMostrar(LED_DESCONECTADO); delay(300);
  }
  ledsMostrar(LED_AGUARDANDO);
}

static void marcarDesconexao() {
  unsigned long agora = millis();
  houveDesconexao = true;
  ledVermelhoAteMs = agora + LED_VERMELHO_TEMPO_MS;
  bloqueioScanAteMs = agora + COOLDOWN_APOS_STOP_MS;
}

static void atualizarLeds() {
  EstadoLed e;
  if (connected && !sessaoEncerrada) {
    e = LED_CONECTADO;                                        // verde (pino 11)
  } else if (houveDesconexao &&
             (LED_VERMELHO_ATE_RECONECTAR || millis() < ledVermelhoAteMs)) {
    e = LED_DESCONECTADO;                                     // vermelho (pino 12)
  } else {
    e = LED_AGUARDANDO;                                       // amarelo (pino 13)
  }
  ledsMostrar(e);
}

// ----------------------------------------------------------------------
// FILTRO DE MEDIA MOVEL APARADA PARA O RSSI REAL (em dBm negativos)
// ----------------------------------------------------------------------
int rssiHistorico[RSSI_JANELA];
int rssiIndice = 0;
int rssiContagem = 0;

void resetarFiltroRssi() {
  rssiIndice = 0;
  rssiContagem = 0;
}

float filtrarRssi(int novoRssi) {
  if (novoRssi < -15 && novoRssi > -115) {
    rssiHistorico[rssiIndice] = novoRssi;
    rssiIndice = (rssiIndice + 1) % RSSI_JANELA;
    if (rssiContagem < RSSI_JANELA) rssiContagem++;
  }

  if (rssiContagem == 0) return RSSI_A_1_METRO;

  if (rssiContagem >= 4) {
    long soma = 0;
    int menor = rssiHistorico[0];
    int maior = rssiHistorico[0];
    for (int i = 0; i < rssiContagem; i++) {
      int v = rssiHistorico[i];
      soma += v;
      if (v < menor) menor = v;
      if (v > maior) maior = v;
    }
    soma -= (menor + maior);
    return (float)soma / (rssiContagem - 2);
  }

  long soma = 0;
  for (int i = 0; i < rssiContagem; i++) {
    soma += rssiHistorico[i];
  }
  return (float)soma / rssiContagem;
}

// ----------------------------------------------------------------------
// MPU6050 - Leitura com Calibracao de Giroscopio (SDA = 8, SCL = 9)
// ----------------------------------------------------------------------
#define MPU6050_ADDR       0x68
#define MPU6050_PWR_MGMT_1 0x6B
#define MPU6050_ACCEL_XOUT 0x3B

#define I2C_SDA 8
#define I2C_SCL 9

const float ACCEL_SCALE = 16384.0;
const float GYRO_SCALE  = 131.0;

float accX = 0, accY = 0, accZ = 0;
float gyroX = 0, gyroY = 0, gyroZ = 0;
float gyroOffsetX = 0, gyroOffsetY = 0, gyroOffsetZ = 0;

void mpu6050Acordar() {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(MPU6050_PWR_MGMT_1);
  Wire.write(0x00);
  Wire.endTransmission(true);
}

void mpu6050Calibrar() {
  Serial.println("[MPU6050] Calibrando giroscopio (mantenha o sensor parado)...");
  long somaGX = 0, somaGY = 0, somaGZ = 0;
  int amostrasValidas = 0;

  for (int i = 0; i < 200; i++) {
    Wire.beginTransmission(MPU6050_ADDR);
    Wire.write(MPU6050_ACCEL_XOUT);
    if (Wire.endTransmission(false) == 0) {
      if (Wire.requestFrom((uint8_t)MPU6050_ADDR, (size_t)14, true) == 14) {
        for (int j = 0; j < 8; j++) Wire.read();
        int16_t gx = (Wire.read() << 8) | Wire.read();
        int16_t gy = (Wire.read() << 8) | Wire.read();
        int16_t gz = (Wire.read() << 8) | Wire.read();
        somaGX += gx;
        somaGY += gy;
        somaGZ += gz;
        amostrasValidas++;
      }
    }
    delay(5);
  }

  if (amostrasValidas > 0) {
    gyroOffsetX = (somaGX / (float)amostrasValidas) / GYRO_SCALE;
    gyroOffsetY = (somaGY / (float)amostrasValidas) / GYRO_SCALE;
    gyroOffsetZ = (somaGZ / (float)amostrasValidas) / GYRO_SCALE;
  }

  Serial.printf("[MPU6050] Offset calibrado -> GX: %.2f | GY: %.2f | GZ: %.2f\n",
                gyroOffsetX, gyroOffsetY, gyroOffsetZ);
}

void mpu6050Iniciar() {
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(100000);
  Wire.setTimeOut(20);
  delay(100);

  mpu6050Acordar();
  delay(50);
  mpu6050Calibrar();
}

void mpu6050Ler() {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(MPU6050_ACCEL_XOUT);
  if (Wire.endTransmission(false) != 0) {
    mpu6050Acordar();
    return;
  }

  uint8_t lidos = Wire.requestFrom((uint8_t)MPU6050_ADDR, (size_t)14, true);
  if (lidos < 14) return;

  int16_t rawAccX = (Wire.read() << 8) | Wire.read();
  int16_t rawAccY = (Wire.read() << 8) | Wire.read();
  int16_t rawAccZ = (Wire.read() << 8) | Wire.read();

  Wire.read(); Wire.read();

  int16_t rawGyroX = (Wire.read() << 8) | Wire.read();
  int16_t rawGyroY = (Wire.read() << 8) | Wire.read();
  int16_t rawGyroZ = (Wire.read() << 8) | Wire.read();

  accX = rawAccX / ACCEL_SCALE;
  accY = rawAccY / ACCEL_SCALE;
  accZ = rawAccZ / ACCEL_SCALE;

  gyroX = (rawGyroX / GYRO_SCALE) - gyroOffsetX;
  gyroY = (rawGyroY / GYRO_SCALE) - gyroOffsetY;
  gyroZ = (rawGyroZ / GYRO_SCALE) - gyroOffsetZ;

  if (abs(gyroX) < 0.35) gyroX = 0.0;
  if (abs(gyroY) < 0.35) gyroY = 0.0;
  if (abs(gyroZ) < 0.35) gyroZ = 0.0;
}

// ----------------------------------------------------------------------
// BLE - callbacks de conexao
// ----------------------------------------------------------------------
class MyClientCallback : public BLEClientCallbacks {
  void onConnect(BLEClient* pclient) {
    quedaFisicaInicioMs = 0;
    ultimaAtividadeMs = millis();
    Serial.println("\n[STATUS] Conexao fisica estabelecida com a Ancora!");
  }

  void onDisconnect(BLEClient* pclient) {
    if (quedaFisicaInicioMs == 0) {
      quedaFisicaInicioMs = millis();
    }
    Serial.println("\n[AVISO] Oscilacao/queda no link BLE. Aguardando 5s antes de desativar...");
  }
};

static void notifyCallback(BLERemoteCharacteristic* pBLERemoteCharacteristic,
                           uint8_t* pData, size_t length, bool isNotify) {
  if (pData == nullptr || length < 4) return;

  char msg[32];
  size_t copyLen = (length < sizeof(msg) - 1) ? length : (sizeof(msg) - 1);
  memcpy(msg, pData, copyLen);
  msg[copyLen] = '\0';

  if (strncmp(msg, "STOP", 4) == 0) {
    sessaoEncerrada = true;
    desconectarSolicitado = true;
    return;
  }

  if (sessaoEncerrada) return;

  if (strncmp(msg, "PING:", 5) == 0) {
    long pingId = atol(msg + 5);
    if (pingId > 0) {
      ultimoPingIdRecebido = pingId;
      ultimaAtividadeMs = millis();
      quedaFisicaInicioMs = 0;
    }
    return;
  }

  if (strncmp(msg, "PING", 4) == 0 || strncmp(msg, "ANCORA", 6) == 0) {
    ultimoPingIdRecebido++;
    ultimaAtividadeMs = millis();
    quedaFisicaInicioMs = 0;
  }
}

void enviarTelemetria() {
  if (sessaoEncerrada) return;
  if (!connected || pClient == nullptr || pRemoteCharacteristic == nullptr) return;
  if (!pClient->isConnected()) return;

  int rssiBruto = pClient->getRssi();
  float rssiDbm = filtrarRssi(rssiBruto);
  float distancia = calcularDistancia(rssiDbm);

  // Nivel Real em dB acima de -100 dBm (diminui conforme se afasta!)
  float sinalRealParaExibir = MOSTRAR_EM_DB_POSITIVO ? (100.0 + rssiDbm) : rssiDbm;
  if (MOSTRAR_EM_DB_POSITIVO && sinalRealParaExibir < 0.0) sinalRealParaExibir = 0.0;

  mpu6050Ler();

  char csv[96];
  snprintf(csv, sizeof(csv), "%.2f,%.1f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f",
           distancia, sinalRealParaExibir,
           accX, accY, accZ,
           gyroX, gyroY, gyroZ);

  pRemoteCharacteristic->writeValue((uint8_t*)csv, strlen(csv), false);
  pacotesEnviados++;

  if (rssiBruto < -15 && rssiBruto > -115) {
    ultimaAtividadeMs = millis();
    quedaFisicaInicioMs = 0;
  }

  Serial.printf("[TX #%u | PING #%ld] CSV: %s\n",
                pacotesEnviados, ultimoPingIdRecebido, csv);
  Serial.printf("[RF REAL] RSSI: %.1f dBm | Nivel Real: %.1f dB | Distancia: %.2f m\n",
                rssiDbm, (100.0 + rssiDbm), distancia);
  Serial.println("--------------------------------------------------");
}

class MyAdvertisedDeviceCallbacks : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice advertisedDevice) {
    if (advertisedDevice.haveServiceUUID() &&
        advertisedDevice.isAdvertisingService(serviceUUID)) {
      Serial.printf("[SCAN] Ancora encontrada! RSSI de anuncio: %d dBm\n",
                    advertisedDevice.getRSSI());
      BLEDevice::getScan()->stop();
      if (myDevice != nullptr) {
        delete myDevice;
        myDevice = nullptr;
      }
      myDevice = new BLEAdvertisedDevice(advertisedDevice);
      doConnect = true;
    }
  }
};

// Configura a potencia do radio do ESP32-S3 no nivel MAXIMO (+9 dBm) em todas as fases
void configurarPotenciaMaximaBle() {
  BLEDevice::setPower(ESP_PWR_LVL_P9);
  #if __has_include("esp_bt.h")
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_DEFAULT, ESP_PWR_LVL_P9);
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_SCAN,    ESP_PWR_LVL_P9);
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_ADV,     ESP_PWR_LVL_P9);
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_CONN_HDL0, ESP_PWR_LVL_P9);
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_CONN_HDL1, ESP_PWR_LVL_P9);
    esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_CONN_HDL2, ESP_PWR_LVL_P9);
  #endif
  Serial.println("[RF] Potencia de transmissao BLE configurada no MAXIMO (+9 dBm).");
}

bool connectToServer() {
  if (pClient == nullptr) {
    pClient = BLEDevice::createClient();
    pClient->setClientCallbacks(new MyClientCallback());
  } else if (pClient->isConnected()) {
    pClient->disconnect();
    delay(100);
  }

  Serial.print("[BLE] Conectando ao endereco (mesmo de longe): ");
  Serial.println(myDevice->getAddress().toString().c_str());

  // Tenta conectar ate 2 vezes seguidas caso o primeiro pacote se perca pela distancia
  bool conectou = pClient->connect(myDevice);
  if (!conectou) {
    delay(150);
    conectou = pClient->connect(myDevice);
  }
  if (!conectou) return false;

  // Assinatura correta de 4 argumentos no core ESP32 3.3.x:
  // minInterval=12 (15ms), maxInterval=24 (30ms), latency=2, timeout=500 (5.0 segundos)
  pClient->updateConnParams(12, 24, 2, 500);

  pClient->setMTU(185);
  delay(150); // Tempo extra para estabilizar pacotes em longa distancia

  // Tenta descobrir o servico (com 1 retentativa se estiver longe)
  BLERemoteService* pRemoteService = pClient->getService(serviceUUID);
  if (pRemoteService == nullptr) {
    delay(200);
    pRemoteService = pClient->getService(serviceUUID);
  }
  if (pRemoteService == nullptr) {
    Serial.println("[BLE] Servico nao encontrado (sinal muito fraco).");
    pClient->disconnect();
    return false;
  }

  pRemoteCharacteristic = pRemoteService->getCharacteristic(charUUID);
  if (pRemoteCharacteristic == nullptr) {
    Serial.println("[BLE] Caracteristica nao encontrada.");
    pClient->disconnect();
    return false;
  }

  Serial.print("[BLE] Conectado com sucesso! MTU: ");
  Serial.println(pClient->getMTU());

  resetarFiltroRssi();
  if (myDevice->haveRSSI()) {
    filtrarRssi(myDevice->getRSSI());
  }

  unsigned long agora = millis();
  ultimaAtividadeMs = agora;
  quedaFisicaInicioMs = 0;
  ultimoEnvioMs = 0;
  ultimoPingIdRecebido = 0;
  desconectarSolicitado = false;
  sessaoEncerrada = false;
  pacotesEnviados = 0;
  houveDesconexao = false;
  connected = true;

  if (pRemoteCharacteristic->canNotify()) {
    pRemoteCharacteristic->registerForNotify(notifyCallback, true);
  }

  atualizarLeds();
  enviarTelemetria();

  return true;
}

void encerrarSessaoCompleta(const char* motivo) {
  Serial.println(motivo);
  sessaoEncerrada = true;
  if (pClient != nullptr && pClient->isConnected()) {
    pClient->disconnect();
  }
  connected = false;
  desconectarSolicitado = false;
  quedaFisicaInicioMs = 0;
  pRemoteCharacteristic = nullptr;
  resetarFiltroRssi();
  marcarDesconexao();
  atualizarLeds();
}

void setup() {
  #ifdef RGB_BUILTIN
    neopixelWrite(RGB_BUILTIN, 0, 0, 0);
  #endif
  neopixelWrite(48, 0, 0, 0);
  neopixelWrite(38, 0, 0, 0);

  ledsIniciar();

  Serial.begin(115200);
  delay(1000);
  Serial.println("[STATUS] Iniciando Bussola (Cliente BLE)...");
  Serial.println("[VERSAO] Firmware " FW_VERSAO);
  Serial.printf("[LEDS] verde=GPIO%u vermelho=GPIO%u amarelo=GPIO%u\n",
                PIN_LED_VERDE, PIN_LED_VERMELHO, PIN_LED_AMARELO);

  mpu6050Iniciar();

  BLEDevice::init("ESP32_Bussola");
  BLEDevice::setMTU(185);
  configurarPotenciaMaximaBle();

  // Configura Scan com 99% de Duty Cycle (escuta quase continua para captar de longe!)
  BLEScan* pBLEScan = BLEDevice::getScan();
  pBLEScan->setAdvertisedDeviceCallbacks(new MyAdvertisedDeviceCallbacks());
  pBLEScan->setInterval(100); // 62.5 ms
  pBLEScan->setWindow(99);    // 61.8 ms (99% do tempo com o receptor aberto!)
  pBLEScan->setActiveScan(true);
}

void loop() {
  atualizarLeds();

  // 1) Processa nova tentativa de conexao
  if (doConnect == true) {
    doConnect = false;
    if (connectToServer()) {
      Serial.println("[STATUS] Conectado! Trocando dados com a Ancora...");
    } else {
      Serial.println("[STATUS] Falha ao conectar.");
      marcarDesconexao();
      atualizarLeds();
    }
  }

  // 2) Verificacao de estabilidade e LIMITADOR DE 5 SEGUNDOS (5000 ms)
  if (connected) {
    unsigned long agora = millis();

    if (desconectarSolicitado) {
      encerrarSessaoCompleta("[STATUS] Ancora desativada no app! Parando envios...");
    }
    else if (pClient == nullptr || !pClient->isConnected()) {
      if (quedaFisicaInicioMs == 0) {
        quedaFisicaInicioMs = agora;
      } else if ((long)(agora - quedaFisicaInicioMs) >= (long)TIMEOUT_DESCONEXAO_MS) {
        encerrarSessaoCompleta("[STATUS] Link fisico perdido por 5 segundos! Desconectando...");
      }
    }
    else {
      quedaFisicaInicioMs = 0;
      long tempoSemAtividade = (long)(agora - ultimaAtividadeMs);
      if (tempoSemAtividade >= (long)TIMEOUT_DESCONEXAO_MS) {
        encerrarSessaoCompleta("[STATUS] Sem resposta da Ancora por 5 segundos! Desconectando...");
      }
    }
  }

  // 3) Envio continuo de telemetria a cada 300ms enquanto conectado
  if (connected && !sessaoEncerrada && pClient != nullptr && pClient->isConnected()) {
    unsigned long agora = millis();
    if ((long)(agora - ultimoEnvioMs) >= (long)INTERVALO_ENVIO_MS) {
      ultimoEnvioMs = agora;
      atualizarLeds();
      enviarTelemetria();
    }
  }

  // 4) Se estiver desconectado e fora do cooldown, busca a Ancora por 4s continuos
  if (!connected && !doConnect && millis() >= bloqueioScanAteMs) {
    atualizarLeds();
    Serial.println("[STATUS] Buscando Ancora na rede (Alcance Maximo +9 dBm)...");
    BLEScan* pBLEScan = BLEDevice::getScan();
    pBLEScan->clearResults();
    pBLEScan->start(4, false);
    delay(50);
  }

  delay(15);
}