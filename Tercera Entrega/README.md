# KipuBankV2: Banco Descentralizado Multi-Token y Gestión de Riesgos 🏦

**Autor:** Sofía Isabella Palladino

**Licencia:** MIT

## 📝 Resumen

**KipuBankV2** es una **refactorización arquitectónica** y **extensión funcional** del contrato `KipuBank` inicial. Este proyecto lo transforma de una simple bóveda de Ether a una plataforma bancaria descentralizada con **soporte multi-token (ETH + ERC20)** y mecanismos avanzados de gestión de riesgos, desarrollado en **Solidity versión 0.8.30**.

La característica central es la **Contabilidad Unificada en USD18**, que utiliza Oráculos de Precios de **Chainlink** para estandarizar la valoración de todos los activos, aplicando límites dinámicos (globales y diarios por usuario) en USD. Incorpora un modelo de **Control de Acceso basado en Roles** para separar las responsabilidades administrativas, de riesgo y operacionales.

---
## ✨ Características Principales

* **Soporte Multi-Activo:** Permite el depósito y retiro de **ETH** y tokens **ERC-20** registrados, permitiendo un banco versátil.
* **Gestión de Riesgo en USD:** Límite de capacidad (**BankCap**) y límite de retiro diario por usuario definidos y controlados en **USD (18 decimales)**, desacoplando el riesgo de la volatilidad cripto.
* **Oráculos de Precios:** Integración con **Chainlink Data Feeds** para valoración de activos en tiempo real y protección crítica contra precios obsoletos (**`StalePrice`**).
* **Seguridad Modular:** Utiliza módulos de **OpenZeppelin** (`AccessControl`, `ReentrancyGuard`, `Pausable`, `SafeERC20`) para máxima robustez y segregación de funciones.
* **Eficiencia:** Soporte para **transferencias internas** entre usuarios, optimizando el gas al evitar interacciones externas innecesarias.
* **Auditoría:** Uso de **Custom Errors** (ahorro de gas en reversión) y **Eventos detallados** (incluyendo valor en USD) para facilitar la trazabilidad y la contabilidad *off-chain*.

---
## 🚀 Mejoras Arquitectónicas y Funcionales Clave

| Área de Mejora | KipuBank V1 (Solidez Básica) | KipuBankV2 (Solidez Avanzada y Segura) | Justificación de la Arquitectura |
| :--- | :--- | :--- | :--- |
| **Tokens Soportados** | Solo ETH (token nativo). | **Multi-Token (ETH como `address(0)` + N tokens ERC20)**. | Aumenta la utilidad del banco y requiere un *mapping* anidado. |
| **Contabilidad / Riesgo** | Límite de depósito (`bankCap`) en unidades crudas de ETH. | Límite de capacidad (`bankCapUsd18`) y control en **USD (18 decimales)**. | Estandariza la medida de riesgo financiero, desacoplándola de la volatilidad del ETH. |
| **Oráculos de Datos** | Sin integración de datos externos. | **Integración Chainlink V3** (`AggregatorV3Interface`). | Obtención de precios verificados en cadena y prevención de *front-running*. |
| **Límites de Retiro** | Límite por transacción. | Límite de retiro **diario por usuario** en USD + protección **`StalePrice`**. | Mitiga el riesgo de agotamiento rápido y protege contra oráculos inactivos. |
| **Administración** | Sin roles, control monolítico. | **Roles Granulares** (`ADMIN`, `OPERATOR`, `RISK`) usando `AccessControl`. | Implementa el **Principio del Mínimo Privilegio (PoLP)** y descentraliza la toma de decisiones. |
| **Seguridad de Interacción** | Patrón CEI. | **Patrón CEI Reforzado** con `nonReentrant` y `SafeERC20`. | Evita ataques de reentrada y asegura que las interacciones con tokens externos no fallen silenciosamente. |

---
## 📐 Notas sobre Decisiones de Diseño Técnico (Justificación Extendida)

El desarrollo en **Solidity 0.8.30** permite el uso de **Custom Errors** y garantiza la protección por defecto contra *overflows* y *underflows*, asegurando un código más limpio y eficiente.

### 1. Modelo de Contabilidad Estandarizada en USD18

#### **Decisión:** Usar USD con 18 decimales (`USD18`) como unidad de cuenta interna.

* **Justificación de Riesgo:** Al basar los límites en USD, el riesgo financiero se desacopla de la volatilidad del activo, proporcionando una métrica de riesgo coherente para múltiples activos.
* **Conversión y Precisión (`Math.mulDiv`):** La conversión se realiza con **`Math.mulDiv` (OpenZeppelin)**, crucial para la **precisión completa** en la compleja fórmula de escalado, previniendo *overflows* o pérdidas de datos.

### 2. Gestión de Riesgo de Precios y Oráculos (Chainlink)

#### **Decisión:** Integración estricta de **`AggregatorV3Interface`** y aplicación de la validación de frescura.

* **Seguridad de Datos:** La función `_getLatestPriceValidated` impone **protección contra precios obsoletos (`StalePrice`)**. Se verifica el precio positivo, la validez del *roundId* y que la antigüedad no exceda el límite (`maxPriceAgeSeconds`).
* **Implicación del *Trade-off*:** El parámetro `maxPriceAgeSeconds` (controlado por el `RISK_ROLE`) equilibra la **seguridad** con la **disponibilidad**.

### 3. Modelo de Control de Acceso Granular y Seguridad de Módulos (OpenZeppelin)

#### **Decisión:** Implementar **siete módulos de OpenZeppelin** para máxima robustez y separación de preocupaciones.

* **`AccessControl.sol`**: Define los roles `ADMIN`, `OPERATOR`, y `RISK`, aplicando el Principio del Mínimo Privilegio (PoLP) para la gobernanza.
* **`ReentrancyGuard.sol`**: Protege **todas** las funciones de depósito y retiro.
* **`Pausable.sol`**: Permite al `OPERATOR_ROLE` suspender temporalmente las funciones críticas en caso de emergencia.
* **`SafeERC20.sol`**: Asegura que las interacciones con tokens ERC20 reviertan si la llamada al token falla.
* **`Math.sol`**: Proporciona las funciones matemáticas seguras (`mulDiv`) para las conversiones de decimales USD18.

### 4. Trazabilidad y Manejo de Errores (Eventos y Custom Errors)

#### **Decisión:** Utilizar **Custom Errors** para la lógica de `require` y **Eventos detallados** para toda la lógica de transferencia de valor.

* **Eficiencia de Manejo de Errores:** Se implementaron **Errores Personalizados (Custom Errors)** para reemplazar las cadenas de texto en `require`. Esta es una práctica moderna de Solidity que **reduce el coste de gas** al revertir.
* **Trazabilidad y Auditoría:** Todos los flujos críticos de valor emiten un **Evento**. Los eventos `Deposit` y `Withdrawal` son cruciales porque registran el **valor convertido a USD18** *junto con* el monto crudo del token, facilitando la auditoría *off-chain*.

### 5. Patrones de Eficiencia de Flujo

#### **Decisión:** Optimizar las transferencias internas y mantener un *mapping* de saldos.

* **Transferencias Internas:** La función `transferInternal` solo ajusta balances en el *mapping* interno, permitiendo movimientos entre usuarios del banco sin costes de gas de transacciones ERC20 externas.
* **Recibe/Fallback Explícito:** La protección con `revert` en `receive()` y `fallback()` fuerza a los usuarios a usar la función `depositETH()`, garantizando la correcta aplicación de los límites y la emisión de eventos.

---
## 🛠️ Detalle del Despliegue en Testnet (Instrucciones y Parámetros)

El proyecto fue desplegado en una Testnet utilizando **Remix IDE** y el proveedor inyectado.

### 1. Componentes Desplegados

| Contrato | Dirección de Despliegue | Parámetros del Constructor | Detalle |
| :--- | :--- | :--- | :--- |
| **`MockV3Aggregator`** | `0x4DA3b837215c9fc10e7AF9ce97c92557C22a605B` | `decimals=8`, `initialAnswer=200000000000` | Simula ETH a **$2,000$ USD** |
| **`MockERC20`** (MKT) | `0xc4f5CD4431e2993D3b2A22Cb3D41C453ca3E85e6` | `name="MockToken"`, `symbol="MKT"`, `decimals=18` | Suministro inicial: $1,000,000 \times 10^{18}$ |
| **`KipuBankV2`** | **`0x21651aB961b03E0E6d2142c90f83Ef5eec732aCD`** | Ver tabla a continuación. | |

### 2. Parámetros de Inicialización de KipuBankV2

| Parámetro del Constructor | Valor Utilizado (en Unidades) | Valor en USD | Observaciones |
| :--- | :--- | :--- | :--- |
| `_bankCapUsd18` | `1000000000000000000000000` | **$1,000,000$ USD** | Límite máximo global del banco (en USD18). |
| `_ethPriceFeed` | `0x4DA3b837215c9fc10e7AF9ce97c92557C22a605B` | N/A | Dirección del Oráculo de ETH/USD (Mock). |
| `_perUserDailyWithdrawLimitUsd18`| `10000000000000000000000` | **$10,000$ USD** | Límite de retiro diario por usuario (en USD18). |

### 3. Direcciones y Roles Clave

| Entidad | Tipo | Identificador |
| :--- | :--- | :--- |
| **Contrato KipuBankV2** | Dirección | **`0x21651aB961b03E0E6d2142c90f83Ef5eec732aCD`** |
| **Cuenta Deployer** | Dirección | `0x7303785d5568e45baA6b2350a3EADfce7F830A2b` (mi wallet) |
| **`DEFAULT_ADMIN_ROLE`** | Rol (Hash) | `0x00...00` (El valor por defecto) |
| **`ADMIN_ROLE`** | Rol (Hash) | `0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775` |
| **`OPERATOR_ROLE`** | Rol (Hash) | `keccak256("OPERATOR_ROLE")` |
| **`RISK_ROLE`** | Rol (Hash) | `keccak256("RISK_ROLE")` |

***Nota:*** *La Cuenta Deployer posee los roles DEFAULT_ADMIN, ADMIN, OPERATOR, y RISK.*

---
## 📂 Estructura del Repositorio

| Archivo/Directorio | Descripción | Contenido Relevante |
| :--- | :--- | :--- |
| `src/KipuBankV2.sol` | **Implementación Principal.** | Roles, Chainlink, ReentrancyGuard, lógica de depósitos/retiros en USD18. |
| `src/MockERC20.sol` | Contrato ERC20 con decimales configurables. | Utilizado para simular activos de terceros en pruebas. |
| `src/MockV3Aggregator.sol` | Contrato simulado de Oráculo Chainlink. | Permite controlar el precio y simular el *stale price* en pruebas locales. |
| `README.md` | Este documento de justificación y guía. | |


---

## ✅ Entregables Finales

1.  **Dirección del Contrato KipuBankV2 Desplegado (Testnet):** **`0x21651aB961b03E0E6d2142c90f83Ef5eec732aCD`**
    **Enlace de Verficiación en Etherscan de KipuBankV2 (Sepolia):** https://sepolia.etherscan.io/address/0xc4f5CD4431e2993D3b2A22Cb3D41C453ca3E85e6#code
  
2.  **Dirección del Contrato MockERC20 Desplegado (Testnet):** **`0xc4f5CD4431e2993D3b2A22Cb3D41C453ca3E85e6`**
    **Enlace de Verificación en Etherscan de MockERC20 (Sepolia):** https://sepolia.etherscan.io/address/0x21651aB961b03E0E6d2142c90f83Ef5eec732aCD#code
   
3.  **Dirección del Contrato MockV3Aggregator Desplegado (Testnet):** **`0x4DA3b837215c9fc10e7AF9ce97c92557C22a605B`**
    **Enlace de Verficiación en Etherscan de MockV3Aggregator (Sepolia):** https://sepolia.etherscan.io/address/0x4DA3b837215c9fc10e7AF9ce97c92557C22a605B#code
