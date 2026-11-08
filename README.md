# Bússola Háptica - Navegação Assistiva P2P

Este repositório contém o código-fonte do projeto de Trabalho de Conclusão de Curso (TCC) focado no desenvolvimento de um sistema de micro-navegação tátil e assistiva para pessoas com surdocegueira. 

O sistema opera através de uma arquitetura Ponto-a-Ponto (Peer-to-Peer) descentralizada, estabelecendo uma comunicação direta via Bluetooth Low Energy (BLE) entre um nó alvo (Smartphone) e um nó receptor (Bússola Vestível), dispensando infraestrutura fixa de rede ou GPS em ambientes internos.

## 🏗️ Arquitetura do Sistema

O projeto é dividido em dois grandes módulos:

### 1. Nó Transmissor - Âncora Móvel (App Flutter)
Aplicativo mobile desenvolvido em Flutter que transforma o smartphone (testado no Samsung Galaxy S21 FE 5G) em uma âncora BLE atuando como Servidor GATT (Peripheral).
* **Foreground Service:** Mantém o rádio BLE transmitindo o sinal de ancoragem de forma ininterrupta em segundo plano.
* **Painel de Telemetria:** Processa e exibe em tempo real, através de uma interface minimalista (Dark Mode), os dados calculados e enviados de volta pelo microcontrolador.

### 2. Nó Receptor - Bússola Háptica (ESP32-S3 + MPU-6050)
Dispositivo vestível focado na extração de contexto físico e atuação tátil/visual. Baseado no Freenove ESP32-S3-WROOM, atua como Cliente BLE (Central).
* **Fusão de Sensores:** Lê diretamente os registradores I2C (sem bibliotecas de terceiros) do sensor inercial MPU-6050 para obter as taxas do giroscópio e acelerômetro.
* **Cálculo de Distância:** Utiliza filtro de média móvel sobre a potência do sinal de rádio (RSSI) com modelo *Log-Distance Path Loss* para estimar a distância até a âncora.
* **Feedback Ativo:** Mapeia a proximidade e o eixo Z (rotação espacial) para acionar o feedback de direcionamento (Motores vibratórios via PWM ou matriz de LEDs de status).

## 🚀 Como Executar

### Pré-requisitos
* **Hardware:** Placa ESP32-S3, módulo sensor MPU-6050 e Smartphone Android 12+ com suporte a BLE.
* **Software:** Arduino IDE (com pacote ESP32 instalado) e Flutter SDK.

### Bússola (Microcontrolador)
1. Abra a pasta `bussola_esp32` na Arduino IDE.
2. Certifique-se de que as conexões I2C do MPU-6050 estão configuradas nas portas SDA e SCL corretas definidas no código.
3. Selecione a placa (ex: ESP32S3 Dev Module) e faça o upload.

### Âncora (Aplicativo Mobile)
1. Abra a pasta `ancora_flutter` no VS Code ou Android Studio.
2. No terminal, execute `flutter pub get` para baixar dependências como `ble_peripheral` e `permission_handler`.
3. Conecte o smartphone Android com Depuração USB ativada.
4. Execute `flutter run` ou compile o APK via `flutter build apk`.
5. Aceite as permissões de Bluetooth e Localização ao abrir o aplicativo pela primeira vez e toque em "ATIVAR ÂNCORA".

## 📡 Protocolo BLE (UUIDs)
Ambos os dispositivos se comunicam de forma autônoma através dos seguintes identificadores restritos:
* **Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
* **Characteristic UUID:** `beb5483e-36e1-4688-b7f5-ea07361b26a8`

## 👨‍💻 Autor
**Pedro Vieira** - [GitHub](https://github.com/PedroVieira0406)
