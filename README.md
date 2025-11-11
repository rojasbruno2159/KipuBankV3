# 🏦 **KipuBankV3**

**Protocolo de depósito con conversión automática a USDC** vía **Uniswap V2** y precios de **Chainlink**, con **control de acceso** y **límite de banca (`bankCap`)** expresado en USDC.  
**Objetivo:** documentar las mejoras, explicar el despliegue/interacción, detallar decisiones de diseño y presentar un **informe de amenazas**, junto con **cobertura y métodos de prueba**.

## 📘 **Visión General**
### **Mejoras respecto a V2**
- **Depósitos generalizados:** admite cualquier token ERC-20 soportado por Uniswap V2 (además de ETH).  
- **Conversión automática a USDC:** todo depósito se swapea a USDC usando **Uniswap V2 Router**.  
- **Integración de swaps automatizados:**  el protocolo realiza internamente el intercambio de tokens por USDC, sin intervención manual del usuario. 
- **Gestión de activos dinámica:** `mapping(address => AssetConfig)` para habilitar/inhabilitar activos y asociarles price feeds.  
- **Límite de exposición:** `bankCap` en USDC; previene sobrecapitalización del protocolo.  
- **Control de acceso (RBAC):** `AccessControl` de OpenZeppelin; solo roles administrativos modifican parámetros críticos.  
- **Librería de decimales:** normalización de montos a **6 decimales (USDC)** para evitar errores de precisión.  
- **Pruebas unitarias:** cobertura ≥ **50%** (ver sección de cobertura para cifras reales).

## ⚙️ **Instalación y Despliegue**
**Requisitos:**  
- **Foundry instalado.**  
- **Dependencias (desde la raíz del repo):**  
`forge install openzeppelin/openzeppelin-contracts`  
`forge install smartcontractkit/chainlink-brownie-contracts`  
`forge install uniswap/v2-periphery`  
- **Compilación:**  
`forge build`  
**Despliegue + Verificación (desde /script o la raíz):**  
`forge script script/DeployKipuBankV3.s.sol --rpc-url "RPC_URL" --private-key "PRIVATE_KEY" --broadcast --verify`

## 💻 **Interacción Básica**
**Ejemplos:**  
- **Consultar el límite del banco:** `KipuBankV3.bankCap();`  
- **Saldo en USDC por usuario:** `KipuBankV3.userBalance(usuario);`  
- **Depositar ETH:** `KipuBankV3.deposit{value: 1 ether}(address(0));`  
- **Depositar ERC-20:**  
`IERC20(token).approve(address(KipuBankV3), amount);`  
`KipuBankV3.deposit(token);`  
- **Retirar USDC:** `KipuBankV3.withdraw(amountUSDC);`  
**Notas:**  
La conversión a **USDC** se ejecuta internamente vía **Uniswap V2**.  
El **bankCap** está expresado en unidades de **USDC (6 decimales)**.  
Solo **roles admin** pueden habilitar nuevos tokens y fijar/ajustar el **bankCap**.

## 🧠 **Decisiones de Diseño y Trade-offs**
- **Oráculos:** uso de `Chainlink AggregatorV3` para obtener precios auditables y robustos.  
- **Swaps:** integración con **Uniswap V2 Router** por su liquidez amplia y API estable.  
- **Decimales:** normalización a **6 decimales (USDC)** para cálculos consistentes.  
- **Acceso:** gestión de permisos mediante **AccessControl** para gobernanza clara.  
- **Límite:** `bankCap` expresado en USDC para controlar exposición total.  
- **Pausa:** aún no implementada; pendiente agregar un **circuito de emergencia**.  
- **Reentrancia:** mitigada por diseño, pero se recomienda agregar **ReentrancyGuard** en V4.

## 🔒 **Informe de Análisis de Amenazas**
**Debilidades Identificadas:**  
- Falta de función **pause()** global para emergencias.  
- **Dependencias externas:** si Chainlink o Uniswap fallan, afecta al protocolo.  
- **Asunción de decimales:** tokens mal configurados pueden romper la normalización.  
- **Ausencia de auditoría externa**, solo pruebas unitarias.  
**Recomendaciones para madurez:**  
- Incorporar **Pausable** y **ReentrancyGuard** de OpenZeppelin.  
- Validar direcciones y decimales antes de habilitar nuevos tokens.  
- Implementar **fuzzing** y **property-based testing** en Foundry.  
- Usar herramientas de análisis estático como **Slither** o **MythX**.  
- Agregar **monitoreo on-chain** de precios y límites.

## 🧪 **Estrategia de Pruebas**
**Framework:** Foundry (`forge test`, `forge coverage`)  
**Estructura de tests:**  
- `test/KipuBankV3Test.t.sol`: flujos principales (depósitos, retiros, límites, roles).  
- `test/Mocks.t.sol`: mocks de oráculos y tokens para aislar lógica.  
**Tipos de pruebas:**  
- **Unitarias:** por función.  
- **Integración:** depósito, swap, balance en USDC.  
- **Validaciones y reverts:** roles, límites, entradas inválidas.  
- **Pendiente:** pruebas de fuzzing, gas snapshots y forks en Sepolia.

## 📊 **Cobertura de Pruebas**
**Cobertura solo de contratos fuente (`src/`)**  
`src/KipuBankV3.sol`  
- **Líneas:** 97.04%  
- **Sentencias:** 95.04%  
- **Branches:** 74.19%  
- **Funciones:** 97.30%

## 📎 **Cómo reproducir tests localmente**
**Ejecutar todas las pruebas:** `forge test -vv`  
**Ver cobertura:** `forge coverage --report lcov`  
**Abrir reporte HTML (si tenés genhtml instalado):** `genhtml lcov.info -o coverage-html && xdg-open coverage-html/index.html`

## 🧾 **Licencia**
**MIT © 2025 – Bruno Rojas / KipuBankV3**

## ✍️ **Autoría**
**Diseño y desarrollo:** Bruno Rojas
