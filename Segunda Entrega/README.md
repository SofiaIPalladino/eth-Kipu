# KipuBank: Contrato Bancario Descentralizado (TP2)

## 📝 Resumen del Proyecto

Este proyecto consiste en el desarrollo e implementación de **KipuBank**, un contrato inteligente simple desplegado en la red de prueba **Sepolia**. El contrato simula un sistema de bóvedas personales donde los usuarios pueden depositar y retirar ETH.

El contrato `KipuBank` utiliza los principios de seguridad de **checks-effects-interactions** y emplea **errores personalizados (Custom Errors)** en Solidity 0.8.30 para proporcionar retroalimentación precisa sobre las fallas de las transacciones.

## 🛠️ Parámetros Inmutables del Despliegue

El contrato se inicializa con dos variables cruciales para su funcionamiento, establecidas en el constructor. Estos valores son inmutables después del despliegue:

| Parámetro del Constructor | Valor Utilizado | Valor en Wei | Propósito |
| :--- | :--- | :--- | :--- |
| `_bankCap` | **10 ETH** | `10000000000000000000` | Límite máximo global de ETH que el contrato puede albergar. |
| `_withdrawalThreshold` | **1 ETH** | `1000000000000000000` | Límite máximo por transacción que un usuario puede retirar de una sola vez. |

---

## ✅ Prueba de Funcionamiento y Verificación

La verificación exitosa del código fuente en Etherscan es la prueba definitiva de que el código en este repositorio es el que se está ejecutando en la red Sepolia.

**1. Dirección del Contrato Desplegado:**
[`0xc06d14B697b039D0859b22A032C9FC44bB388C0c`]

**2. Enlace de Verificación en Etherscan (Sepolia):**


[`https://sepolia.etherscan.io/address/0xc06d14B697b039D0859b22A032C9FC44bB388C0c#code`]

---

## ⚙️ Configuración de Compilación

| Parámetro | Valor |
| :--- | :--- |
| **Solidity Version** | `v0.8.30` |
| **Compiler Version** | `v0.8.30+commit.73712a01` |
| **EVM Version** | `Prague` |
