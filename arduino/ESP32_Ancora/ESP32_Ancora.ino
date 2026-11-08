/*
 * ======================================================================
 *  ANCORA - Servidor BLE
 * ======================================================================
 * Placa: Freenove ESP32-S3-WROOM (N16R8)
 * Config na IDE: Board = ESP32S3 Dev Module | PSRAM = OPI PSRAM
 *
 * FUNCAO DESTE DISPOSITIVO:
 * A ancora e o ponto de referencia FIXO. Ela fica anunciando sua
 * presenca via Bluetooth Low Energy (BLE) e, quando a Bussola conecta,
 * envia pacotes periodicos por "notify".
 *
 * A Bussola (o outro dispositivo) e quem calcula a distancia,
 * medindo a forca do sinal (RSSI) que chega dela. A Ancora nao
 * precisa fazer nenhum calculo, apenas transmitir.
 * ======================================================================
 */

#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

// UUIDs: funcionam como o "endereco" do servico e da caracteristica.
// Tem que ser IDENTICOS nos dois codigos (Ancora e Bussola).
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;

bool dispositivoConectado = false;
bool lostConnection = false;
int contadorPacotes = 0;

// ----------------------------------------------------------------------
// Callbacks de conexao/desconexao do servidor BLE.
// Sao chamados automaticamente pela pilha BLE quando o estado muda.
// ----------------------------------------------------------------------
class MyServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      dispositivoConectado = true;
      Serial.println("\n[STATUS] Bussola conectada com sucesso!");
    }

    void onDisconnect(BLEServer* pServer) {
      dispositivoConectado = false;
      lostConnection = true;
      Serial.println("\n[STATUS] Conexao perdida. Retomando anuncio...");
    }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Inicializa a pilha BLE com o nome que aparece nos scans de outros
  // dispositivos.
  BLEDevice::init("ESP32_Ancora");

  // Cria o servidor BLE e associa os callbacks acima a ele.
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Cria o "servico" (um agrupador logico de caracteristicas).
  BLEService* pService = pServer->createService(SERVICE_UUID);

  // Cria a caracteristica dentro do servico. As flags definem o que
  // o cliente pode fazer com ela:
  //   READ   -> cliente pode ler o valor atual
  //   WRITE  -> cliente pode escrever um valor
  //   NOTIFY -> servidor pode empurrar atualizacoes automaticas
  pCharacteristic = pService->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ |
      BLECharacteristic::PROPERTY_WRITE |
      BLECharacteristic::PROPERTY_NOTIFY);

  // O descriptor BLE2902 e obrigatorio para que o NOTIFY funcione de
  // acordo com o padrao BLE (ele guarda se o cliente "se inscreveu"
  // para receber notificacoes).
  pCharacteristic->addDescriptor(new BLE2902());

  // Liga o servico (a partir daqui ele fica visivel/utilizavel).
  pService->start();

  // Configura e inicia o "advertising" (o anuncio de radio que permite
  // a Bussola encontrar esta Ancora fazendo um scan).
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);
  BLEDevice::startAdvertising();

  Serial.println("[STATUS] Servidor iniciado. Emitindo sinal BLE...");
  Serial.print("[STATUS] MAC desta Ancora: ");
  Serial.println(BLEDevice::getAddress().toString().c_str());
}

void loop() {
  // Se a conexao caiu, precisamos religar o advertising manualmente,
  // senao a Ancora fica "muda" e nunca mais e encontrada de novo.
  if (lostConnection) {
    delay(1000);
    BLEDevice::startAdvertising();
    lostConnection = false;
  }

  // Enquanto a Bussola estiver conectada, envia um pacote por segundo.
  // E esse pacote que dispara o RSSI que a Bussola usa pra medir
  // distancia (o RSSI vem "de graca" em qualquer troca BLE, nao
  // precisa ir dentro do texto do pacote).
  if (dispositivoConectado) {
    contadorPacotes++;
    String pacote = "Ancoragem Ativa - Pacote #" + String(contadorPacotes);

    pCharacteristic->setValue(pacote.c_str());
    pCharacteristic->notify();

    Serial.print("Enviado: ");
    Serial.println(pacote);

    delay(1000);
  }
}
