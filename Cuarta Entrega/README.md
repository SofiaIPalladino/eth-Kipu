# KipuBankV3 — Banco DeFi con swaps automáticos a USDC 🏦

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)  [![Solidity 0.8.30](https://img.shields.io/badge/Solidity-0.8.30-blue)]()  [![Tests](https://img.shields.io/badge/tests-passing-brightgreen)]()  

Última actualización: 2025-11-09  
Autor: Sofía Isabella Palladino (SofiaIPalladino)  
Licencia: MIT

Resumen
--------------------------
Se actualizó el contrato existente KipuBankV2 hacia una aplicación DeFi más avanzada y real: KipuBankV3.

Requisitos implementados en este repositorio:
- Aceptar cualquier token soportado por Uniswap V2 (además de ETH y USDC).
- Intercambiar automáticamente (on‑chain) los tokens depositados a USDC usando un router compatible con Uniswap V2.
- Acreditar el monto resultante en el balance interno del usuario en USDC.
- Respetar el límite máximo global del banco (bankCap) en representación `usd18` y preservar la lógica principal de KipuBankV2 (control de owner/roles, depósitos y retiros).

Este README documenta cómo el contrato satisface cada requisito del examen, las decisiones de diseño, instrucciones de despliegue e interacción, y las consideraciones de seguridad y trade‑offs.

Direcciones conocidas (proporcionadas)
-------------------------------------
- MockUSDC: `0xa5cc420976142544d04482E82a0bD0E079f8cc71`
  -   Enlace de Verficiación en Etherscan: https://sepolia.etherscan.io/address/0xa5cc420976142544d04482E82a0bD0E079f8cc71#code  

- MockUniswapFactoryMock: `0xc2D2FEa7C61726E8BF7b94274549ca3075907365`
  -    Enlace de Verficiación en Etherscan : https://sepolia.etherscan.io/address/0xc2D2FEa7C61726E8BF7b94274549ca3075907365#code

- MockUniswapRouterMock: `0xa80A73E0643e1d7F83aEa7E0C5e2452960596533`
  -   Enlace de Verficiación en Etherscan: https://sepolia.etherscan.io/address/0xa80A73E0643e1d7F83aEa7E0C5e2452960596533#code

- KipuBankV3 (ejemplo desplegado): `0xB408E7E2496D612bb84ee2d09bFAc823BE4A7C00`
  -    Enlace de Verficiación en Etherscan: https://sepolia.etherscan.io/address/0xB408E7E2496D612bb84ee2d09bFAc823BE4A7C00#code

Contenido del repositorio
-------------------------
- src/KipuBankV3.sol — contrato principal (implementa swaps, contabilidad y controles).
- src/MockUSDC.sol — mock ERC20 con decimals configurable (pruebas).
- src/MockUniswapFactoryMock.sol — factory mock.
- src/MockUniswapRouterMock.sol — router mock.
- scripts/deploy-mocks-and-kipu.js — despliegue de mocks + KipuBankV3.
- test/kipubankv3.test.js — tests básicos (USDC deposit, internal transfer, admin adjust, intento swap).
- hardhat.config.js, package.json — configuración y scripts.

Cumplimiento de los objetivos del examen
---------------------------------------
1. Manejar cualquier token intercambiable en Uniswap V2
   - El contrato intenta construir rutas hacia USDC consultando la factory (`getPair`) y probando:
     - par directo token ⇄ USDC,
     - token ⇄ WETH ⇄ USDC,
     - o rutas con `intermediaries` configurables por ADMIN.
   - Si no existe ruta válida, la operación revierte con `NoUSDCpair`.

2. Ejecutar swaps de tokens dentro del smart contract
   - Se usa `IUniswapV2Router02` para `getAmountsOut`, `swapExactTokensForTokens` y `swapExactETHForTokens`.
   - Antes del swap se calcula el `expected` y un `amountOutMin` aplicando `slippageBps`.
   - Tras el swap se mide USDC recibido con `balanceBefore`/`balanceAfter`.

3. Preservar la funcionalidad de KipuBankV2
   - Se mantienen: control de owner/roles con `AccessControl`, depósitos/retiros, transferencia interna, contabilidad y eventos.

4. Respetar el límite del banco (bankCap)
   - Tras recibir USDC del swap se convierte la cantidad raw a `usd18` mediante `_toUsd18`.
   - Se verifica que `totalDepositedUsd18 + usd18 <= bankCapUsd18`. Si excede, la transacción revierte y no se actualiza la contabilidad.

Decisiones de diseño y trade‑offs
---------------------------------
- Moneda interna y contabilidad:
  - Saldo de usuario: USDC raw (ej. 6 decimales).  
  - Límites/contabilidad: `usd18` (18 decimales) para homogeneidad entre tokens.
  - Trade‑off: requiere conversiones de decimales en cada paso; ventaja: comparabilidad clara en USD.

- Swaps mediante Uniswap V2 Router:
  - Reutiliza infraestructura existente; reduce código de mercado propio.
  - Trade‑off: dependencia externa y necesidad de validaciones (slippage, rutas).

- Rutas y `intermediaries`:
  - Permitidas rutas directas y multihop via WETH u otros intermediarios configurables.
  - Trade‑off: rutas más largas consumen más gas y aumentan riesgo de slippage.

- Tokens fee-on-transfer:
  - Uso de medición `balanceBefore`/`balanceAfter` al recibir tokens y al medir USDC tras swap.
  - Beneficio: exactitud en depósitos con tokens que cobran fee o tienen hooks.

- Manejo de allowances:
  - `_ensureAllowance` con fallback low‑level (approve(0) + approve(amount)) para tokens no estándar.
  - Trade‑off: llamadas low‑level aumentan complejidad pero aumentan compatibilidad.

- Seguridad:
  - Uso de `ReentrancyGuard`, `Pausable`, `SafeERC20`, `AccessControl` y custom errors para eficiencia de gas.
  - emergencyWithdraw restringido: no permite extraer USDC.

Criterios de evaluación — cómo se abordaron
-------------------------------------------
- Correctitud: swaps realizados on‑chain; USDC resultante contabilizado; bankCap respetado antes de actualizar balances.
- Seguridad y gas: SafeERC20, ReentrancyGuard, Pausable, manejo robusto de allowances y medición de cantidades reales.
- Calidad de código: modularidad (funciones internas dedicadas), comentarios y eventos para auditoría.
- Dependencias: uso apropiado de OpenZeppelin y de interfaces Uniswap V2; mocks incluidos para testing.
- Aprendizaje: patrones y prácticas vistas en clases y materiales del curso aplicados consistentemente.

Instrucciones: instalación, tests y despliegue
----------------------------------------------
Requisitos
- Node.js >= 16
- npm o yarn
- Variables de entorno si despliegue a testnet: RPC_URL y DEPLOYER_PRIVATE_KEY

Instalación local
```bash
git clone https://github.com/SofiaIPalladino/eth-Kipu.git
cd "eth-Kipu/Cuarta Entrega"
npm install
npm run compile
```

Ejecutar tests (con mocks incluidos)
```bash
npm run test
```

Despliegue local (mocks + KipuBankV3)
```bash
# Opcional: en otra terminal
npx hardhat node

# En terminal nueva (usa cuenta de node local)
npm run deploy:local
# Ejecuta: npx hardhat run --network localhost scripts/deploy-mocks-and-kipu.js
```

Despliegue en Sepolia (ejemplo)
```bash
export SEPOLIA_RPC="https://sepolia.infura.io/v3/<INFURA_KEY>"
export DEPLOYER_PRIVATE_KEY="0x..."   # cuenta deployer

npm run deploy:sepolia
```
- Ajustar `scripts/deploy-mocks-and-kipu.js` si se desea usar routers/factories reales (evitar desplegar mocks en testnet).

Verificación (Etherscan) — ejemplo
```bash
npm i -D @nomiclabs/hardhat-etherscan
# configurar ETHERSCAN_API_KEY en hardhat.config.js

npx hardhat verify --network sepolia <KIPUBANKV3_ADDRESS> \
  "10000000000000000000000" \
  "0xa5cc420976142544d04482E82a0bD0E079f8cc71" \
  "0xa80A73E0643e1d7F83aEa7E0C5e2452960596533" \
  "1000000000000000000000"
```
(Ajustar valores según despliegue real y red.)

Referencia rápida de funciones públicas
-------------------------------------
- depositETH() payable — Depósito de ETH y swap a USDC.
- depositToken(address token, uint256 amount) — Deposita ERC20 y realiza swap si no es USDC.
- withdraw(uint256 usdcRawAmount) — Retira USDC del balance interno (aplica límites diarios).
- transferInternal(address to, uint256 usdcRawAmount) — Transferencia interna de USDC entre usuarios.
- supportsToken(address token) view returns (bool) — Indica si token puede rutearse a USDC.
- getUserUSDCBalance(address user) view returns (uint256) — Balance interno USDC.

Funciones administrativas (roles)
- registerToken(token, feed, decimals)
- setUniswapRouter(newRouter)
- setIntermediaries(list)
- setSlippageBps(newBps)
- setBankCapUsd18(newCap)
- setPerUserDailyWithdrawLimitUsd18(newLimit)
- adminAdjustTotalUsd18(delta, reason)
- updatePriceFeed(token, newFeed)
- pause(), unpause(), emergencyWithdraw(...)

Flujo interno del swap (resumen)
--------------------------------
1. Recepción del token (balanceBefore/after para contar el recibido).  
2. Construcción y validación de la ruta hacia USDC.  
3. Estimación con `getAmountsOut` y cálculo de `amountOutMin` aplicando `slippageBps`.  
4. Ejecución del swap (ETH o token).  
5. Medición de USDC efectivo recibido.  
6. Conversión a `usd18` y verificación contra `bankCapUsd18`.  
7. Si la verificación pasa, actualización de balances y contabilidad; si no, revert.

