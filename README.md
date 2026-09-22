# DT1 Agent

App iOS pessoal para diabetes tipo 1 com FreeStyle Libre: glicemia em tempo real via LibreLinkUp, insulina e hidratos ativos, sugestão de bólus que tem em conta a comida ainda a ser absorvida, gordura/proteína pelo método de Varsóvia, e alarmes. Tudo corre no iPhone — sem servidor, sem contas, sem analytics.

> **English summary.** DT1 Agent is a self-built iOS app for people with type 1 diabetes using a FreeStyle Libre sensor. It reads glucose from the LibreLinkUp follower API (no server — the phone talks to LibreLinkUp directly, protocol based on [pylibrelinkup](https://github.com/robberwick/pylibrelinkup)), tracks insulin/carbs on board, suggests COB-aware boluses with fat/protein units (Warsaw method), and raises low/high/forecast alarms. **The app follows your iPhone's language: English, or Portuguese on a phone set to Portuguese. Values are in mg/dL only.** In the setup steps below, *Ajustes → Rácios e alvos* is *Settings → Ratios & targets* in English. It is not a medical device and is not on the App Store: you build it yourself with Xcode. Read the safety notice below before using it.

---

## ⚠️ Aviso importante — lê antes de usar

- **Isto não é um dispositivo médico.** Não tem marcação CE nem aprovação da FDA, e não está na App Store (as regras da Apple não permitem calculadoras de dose de particulares).
- **As sugestões de dose são apoio à decisão, não uma ordem.** Confirma sempre com o teu critério e com os valores definidos pela tua equipa de diabetes. Se os sintomas não batem com o número, confia nos sintomas e mede na ponta do dedo.
- **Não substitui os alarmes da app oficial do sensor.** Mantém os alarmes da FreeStyle Libre ativos.
- **Usa uma API não oficial.** A LibreLinkUp não tem API pública; esta app usa a mesma que a app LibreLinkUp usa. A Abbott pode alterá-la ou bloqueá-la a qualquer momento, e não autoriza formalmente este uso. Este projeto não tem qualquer ligação à Abbott.
- **Sem garantias** (licença MIT). Instalas e usas por tua conta e risco.

---

## Índice

1. [O que a app faz](#1-o-que-a-app-faz)
2. [O que precisas](#2-o-que-precisas)
3. [Passo 1 — Criar a conta de seguidor na LibreLinkUp](#3-passo-1--criar-a-conta-de-seguidor-na-librelinkup)
4. [Passo 2 — Compilar e instalar no iPhone](#4-passo-2--compilar-e-instalar-no-iphone)
5. [Passo 3 — Configurar a app](#5-passo-3--configurar-a-app)
6. [Como funciona a sugestão de bólus](#6-como-funciona-a-sugestão-de-bólus)
7. [Gordura e proteína (FPU)](#7-gordura-e-proteína-fpu)
8. [O ecrã "Baixa"](#8-o-ecrã-baixa)
9. [Alarmes](#9-alarmes)
10. [Como os dados chegam à app](#10-como-os-dados-chegam-à-app)
11. [Limitações conhecidas](#11-limitações-conhecidas)
12. [Privacidade](#12-privacidade)
13. [Resolução de problemas](#13-resolução-de-problemas)
14. [Para programadores](#14-para-programadores)
15. [Créditos e licença](#15-créditos-e-licença)

---

## 1. O que a app faz

| Separador | O que tem |
|---|---|
| **Início** | Glicemia atual com seta de tendência e há quantos minutos foi medida, insulina ativa (IOB), hidratos ativos (COB), gráfico das últimas 12 h, e os botões **Tratamento**, **Exercício** e **Baixa**. |
| **Histórico** | Gráfico com zoom, refeições e doses no tempo, % no alvo do período. |
| **Progresso** | Calendário com a % no alvo de cada dia e o streak de dias acima do teu objetivo. |

- **Tratamento** — o fluxo único para comer e/ou injetar: calculadora do rótulo (hidratos, proteína, gordura por 100 g), FPU calculado automaticamente, sugestão de dose ajustável, e hora retroativa (para registos feitos mais tarde).
- **Refeições frequentes** — guardas refeições que repetes e registas com um toque.
- **Lembrete de basal** — opcional: todos os dias a partir das 05:00, até confirmares.
- **Idioma** — a app segue o idioma do iPhone: português se o telemóvel estiver em português (de Portugal ou do Brasil), inglês em qualquer outro caso. Os nomes dos ecrãs neste guia são os da versão portuguesa.

---

## 2. O que precisas

- Um **Mac** com **Xcode 26 ou mais recente** (grátis na Mac App Store).
- **xcodegen** — gera o projeto Xcode a partir de `ios/project.yml`:
  ```bash
  brew install xcodegen
  ```
  (Se não tens o Homebrew: https://brew.sh)
- Um **iPhone com iOS 17 ou mais recente** e um cabo.
- Um **Apple ID**. Serve uma conta gratuita; a conta de programador paga (99 €/ano) evita reinstalar de 7 em 7 dias — ver [passo 2](#4-passo-2--compilar-e-instalar-no-iphone).
- Um sensor **FreeStyle Libre** a funcionar com a app oficial (FreeStyle LibreLink / Libre 3).

---

## 3. Passo 1 — Criar a conta de seguidor na LibreLinkUp

A app **não** usa a conta da app do sensor. Usa uma conta de **seguidor** da LibreLinkUp — a mesma que um familiar usaria para acompanhar a tua glicemia. Vais "seguir-te a ti próprio".

1. **Escolhe um email diferente** do da tua conta LibreLink/LibreView (pode ser um endereço novo que controles).
2. **Na app do sensor** (FreeStyle LibreLink / Libre 3): *Menu → Aplicações ligadas → LibreLinkUp → Adicionar ligação* e convida esse email.
3. **Instala a app LibreLinkUp** (App Store) e cria uma conta com esse email.
4. **Aceita o convite** dentro da LibreLinkUp, e aceita os termos de utilização e a política de privacidade que ela pedir.
5. Confirma que vês a tua glicemia na LibreLinkUp. Se vês, a conta está pronta.

> Faz sempre o primeiro login na app LibreLinkUp oficial. Se houver termos por aceitar, a DT1 Agent mostra "A LibreLinkUp pede uma ação na app oficial" até os aceitares lá.

O email e a password desta conta de seguidor são o que vais pôr na DT1 Agent.

---

## 4. Passo 2 — Compilar e instalar no iPhone

### 4.1 Descarregar o código

```bash
git clone https://github.com/pegpassalacqua/DT1Agent_public.git
cd DT1Agent_public/ios
```

### 4.2 Pôr os teus identificadores

Abre `ios/project.yml` e muda as duas linhas no topo:

```yaml
settings:
  base:
    DT1_BUNDLE_ID: com.yourname.dt1agent   # troca "yourname" por algo teu, ex.: com.anasilva.dt1agent
    DEVELOPMENT_TEAM: ""                   # o teu Team ID (ver abaixo)
```

- **Bundle ID** — qualquer identificador único em formato "domínio invertido". Tem de ser só teu.
- **Team ID** — no Xcode: *Settings → Accounts*, adiciona o teu Apple ID, seleciona a equipa (*Personal Team* se for conta gratuita). O Team ID é o código de 10 caracteres. Também podes deixar vazio e escolher a equipa no Xcode (passo 4.4) — mas terás de o voltar a escolher sempre que corras `xcodegen`.

### 4.3 Gerar o projeto

```bash
xcodegen generate
open Glucose.xcodeproj
```

### 4.4 Instalar

1. Liga o iPhone ao Mac. No iPhone: *Definições → Privacidade e segurança → Modo de programador* → ativar (o iPhone reinicia).
2. No Xcode, escolhe o teu iPhone no seletor de destino, no topo da janela.
3. Se o Team ID ficou vazio: seleciona o projeto *Glucose* → alvo *Glucose* → *Signing & Capabilities* → *Team*.
4. Carrega em ▶ (*Run*). A primeira compilação demora alguns minutos. O esquema instala a versão **Release** (mais rápida).
5. No iPhone, a primeira vez: *Definições → Geral → VPN e gestão de dispositivos* → confiar no teu Apple ID.

### 4.5 Conta gratuita vs paga

| | Conta gratuita | Conta paga (99 €/ano) |
|---|---|---|
| Validade da instalação | **7 dias** — depois a app deixa de abrir e tens de voltar a carregar em ▶ | 1 ano |
| Dados ao reinstalar | Mantêm-se (mesmo bundle ID) | Mantêm-se |

> **Se o ▶ encravar** (iPhone preso em "Preparing", comum depois de atualizar o iOS), instala por linha de comandos:
> ```bash
> xcodebuild -project Glucose.xcodeproj -scheme Glucose -configuration Release \
>   -destination 'generic/platform=iOS' -derivedDataPath build \
>   -allowProvisioningUpdates build
> xcrun devicectl list devices          # copia o Identifier do teu iPhone
> xcrun devicectl device install app --device <IDENTIFIER> \
>   build/Build/Products/Release-iphoneos/Glucose.app
> ```

---

## 5. Passo 3 — Configurar a app

1. **Permite notificações** quando a app pedir.
2. **Ajustes (roda dentada no Início) → LibreLinkUp**: email e password da **conta de seguidor** → *Testar ligação*. Deve aparecer "Ligado" e, no Início, a tua glicemia.
3. **Ajustes → Rácios e alvos** — obrigatório para sugestões de dose. Até guardares, a app **não sugere doses nem hidratos de resgate**. Preenche com os valores da tua equipa de diabetes:

   | Campo | O que é | Exemplo (não é recomendação) |
   |---|---|---|
   | Rácio insulina : hidratos (ICR) | Quantos gramas de hidratos 1 U cobre | 1 U cobre 10 g |
   | Fator de sensibilidade (ISF) | Quanto 1 U baixa a glicemia | 1 U baixa 40 mg/dL |
   | Glicose alvo | Para onde apontam as correções | 110 mg/dL |
   | Duração de ação da insulina (DIA) | Quanto tempo a insulina rápida está ativa | 4 h |
   | Incremento da caneta | A menor dose que a tua caneta marca | 1 U ou 0,5 U |
   | Intervalo alvo (mín./máx.) | O teu "no alvo" — usado em **tudo** (secção 9) | 70–180 mg/dL |

   Aceita vírgula ou ponto decimal (`3,5` ou `3.5`).
4. **Opcional — Basal diária**: define a tua dose de insulina lenta para ter um lembrete todas as manhãs. A 0 fica desligado.
5. **Opcional — Objetivo de tempo no alvo**: a % diária que conta para o streak (a referência clínica habitual é 70 %).
6. **Opcional — Puxar últimos 14 dias**: preenche o histórico com as leituras de eventos dos últimos 14 dias (ver secção 10).

### Para os alarmes funcionarem

- **Não feches a app à força** (deslizar para cima no seletor de apps). Os alarmes precisam que a app esteja viva em segundo plano; fica aberta sozinha graças a um som silencioso — é a mesma técnica que o xDrip4iOS usa.
- O alarme de **baixa** toca mesmo com o iPhone em silêncio, mas **precisa de volume**: não deixes o volume no mínimo.
- O modo de poupança de energia pode reduzir a atividade em segundo plano.

---

## 6. Como funciona a sugestão de bólus

A maioria das calculadoras faz `dose = hidratos/ICR + (glicemia − alvo)/ISF − IOB`. Isto **penaliza duas vezes** a insulina que acabaste de dar para comida que acabaste de comer: essa insulina aparece como "insulina a mais" quando na verdade está a cobrir hidratos que ainda estão a ser absorvidos. A DT1 Agent projeta primeiro para onde vai a glicemia, contando **ao mesmo tempo** com a insulina ativa e os hidratos ativos:

```
glicemia prevista = glicemia − IOB × ISF + COB × (ISF / ICR)
dose refeição     = hidratos novos / ICR
dose correção     = (glicemia prevista − alvo) / ISF
dose sugerida     = dose refeição + dose correção, arredondada PARA BAIXO ao incremento da caneta
```

**Exemplo** (ICR 10, ISF 40, alvo 110): glicemia 180, IOB 1 U, COB 20 g, vais comer 50 g.

| | Cálculo | Resultado |
|---|---|---|
| Glicemia prevista | 180 − 1×40 + 20×(40/10) | 220 mg/dL |
| Dose refeição | 50 / 10 | 5,0 U |
| Dose correção | (220 − 110) / 40 | 2,75 U |
| Total | 7,75 U → arredondado para baixo | **7 U** (caneta de 1 U) ou **7,5 U** (caneta de 0,5 U) |

Regras de segurança:

- **Arredonda sempre para baixo** a dose, e **para cima** os hidratos de resgate. Na dúvida, menos insulina / mais hidratos.
- **Só usa leituras frescas.** No Tratamento, se a última leitura tiver mais de 5 minutos, a app pede-te a glicemia medida na ponta do dedo; qualquer sugestão recusa leituras com mais de 15 minutos.
- **Se o cálculo previr uma baixa**, em vez de insulina a app sugere **hidratos de resgate** (secção 8) e dose 0.
- Os FPU da refeição nova **não entram na dose de agora**; ficam registados e entram nos hidratos ativos quando começarem a atuar (secção 7).
- **A sugestão é ajustável** — escolhes o que vais injetar. Fica registado se aceitaste ou alteraste.

### Insulina ativa (IOB)

Curva exponencial do OpenAPS/oref0 (a mesma do Loop), com pico aos 75 minutos (valor por defeito do oref0 para insulinas rápidas) e duração igual à DIA que configuraste. A insulina **basal não conta** para o IOB — cobre as necessidades de fundo, não as refeições, tal como em todos os sistemas open-source.

### Hidratos ativos (COB)

- **Hidratos rápidos**: começam a ser absorvidos **15 minutos** depois de comer, a **30 g por hora**, de forma linear.
- **Gordura e proteína**: ver a secção seguinte.

As duas partes somam-se.

---

## 7. Gordura e proteína (FPU)

Refeições gordas ou com muita proteína sobem a glicemia **horas depois**. A app usa o **método de Varsóvia** (Pankowska et al., 2012):

```
FPU = (gordura em g × 9 + proteína em g × 4) / 100
1 FPU ≈ 10 g de hidratos, absorvidos devagar
```

Não introduzes FPU à mão: pões os valores do rótulo na calculadora do Tratamento e o FPU é calculado.

| FPU | Duração da absorção |
|---|---|
| até 1 | 3 h |
| até 2 | 4 h |
| até 3 | 5 h |
| mais de 3 | 8 h |

- A absorção **começa 2 horas depois** de comer. Este atraso **não vem do método de Varsóvia** (que não define atraso); é uma calibração pessoal do autor original. Cada pessoa é diferente.
- A **fibra** é registada mas **não altera** o cálculo: não existe fórmula validada, e a ADA desaconselha descontá-la automaticamente.

**Exemplo:** 100 g de um alimento com 30 g de gordura e 25 g de proteína → FPU = (30×9 + 25×4)/100 = 3,7 FPU ≈ 37 g de hidratos lentos, a entrar a partir das 2 h e ao longo de 8 h. É exatamente o tipo de subida tardia que o **alarme de previsão** (secção 9) apanha.

---

## 8. O ecrã "Baixa"

Responde a "quantos hidratos devo comer agora?". Calcula a glicemia prevista (secção 6) sem refeição nova:

- Se a previsão ficar **abaixo do mínimo do intervalo**: sugere `(alvo − previsão) × ICR / ISF` gramas, arredondado para cima aos 5 g, e deixa registar com um toque. Registar silencia o alarme de baixa durante 20 minutos.
- Se não houver baixa prevista, diz-to — e lembra que, se te sentes em hipo, os sintomas ganham ao cálculo.
- Sem leitura dos últimos 15 minutos, ou sem perfil configurado: não calcula e mostra a **regra clássica — 15 g de hidratos rápidos e reavaliar em 15 minutos**.

**Exemplo** (ICR 10, ISF 40, alvo 110): glicemia 80 com 1 U de IOB → previsão 80 − 40 = 40 → (110 − 40) × 10 / 40 = 17,5 → **20 g**.

---

## 9. Alarmes

### Um único intervalo alvo

O **intervalo alvo** (mínimo/máximo, por defeito 70–180 mg/dL, o consenso internacional) é usado em **tudo**: a % no alvo, o calendário e o streak, as linhas dos gráficos, as cores e os três alarmes. "No alvo" = entre o mínimo e o máximo, **inclusive**.

| Cor | Significado |
|---|---|
| 🟢 Verde | Dentro do intervalo |
| 🔴 Vermelho | Abaixo do mínimo |
| 🟠 Laranja | Acima do máximo |

### Os três alarmes

Os alarmes são avaliados **sempre que chega uma leitura nova**, e só um se aplica de cada vez.

| Alarme | Dispara quando | Silenciado quando | Repete | Som |
|---|---|---|---|---|
| **Baixa** | Glicemia **abaixo do mínimo** | Nos **20 min** a seguir a registar hidratos. **Abaixo de 55 mg/dL nunca é silenciado.** | A cada **15 min** enquanto continuares baixo | **Forte e contínuo, ecrã inteiro**, toca mesmo em modo silencioso, até carregares em "Parar alarme" |
| **Alta** | Glicemia **acima do máximo** | Nas **2 h** a seguir à última injeção de bólus/correção (a basal não conta) — a insulina ainda não teve tempo de atuar | A cada **30 min** | **Suave**: um toque de três notas e um aviso discreto no topo |
| **Previsão** | Glicemia **dentro do intervalo**, mas a **previsão** (a mesma do ecrã "Baixa") sai do intervalo, para cima ou para baixo | Nas **2 h** a seguir à última injeção. Só funciona com o perfil configurado. | A cada **30 min** | **Suave**, como a alta |

A **previsão** existe para o caso que as outras não apanham: estás no alvo agora, mas uma refeição gorda de há 2–3 horas (FPU) ainda vai fazer subir. Exemplo: glicemia 130, refeição e bólus de há 2,5 h, a refeição com 4 FPU → a previsão passa de 180 → aviso suave antes de a subida acontecer.

Além do som dentro da app, cada alarme gera também uma notificação do iOS, que funciona como reserva se o iOS tiver suspendido a app.

---

## 10. Como os dados chegam à app

- **Com a app aberta ou em segundo plano**: pede dados à LibreLinkUp **logo ao abrir** e depois **a cada ~5 minutos** (a LibreLinkUp só atualiza a esse ritmo).
- **Quando quiseres**: puxa o ecrã Início para baixo, ou toca no valor da glicemia.
- **Com a app suspensa pelo iOS**: o iOS acorda-a de vez em quando, sem horário garantido (no mínimo cerca de 15 minutos). Como a LibreLinkUp devolve sempre as **últimas 12 horas**, qualquer despertar nesse período recupera o que faltava.
- **Últimos 14 dias** (*Ajustes → Puxar últimos 14 dias*): a LibreLinkUp só guarda, para esse período, as leituras associadas a eventos/alarmes — não o traço contínuo. Serve para dar algum contexto ao calendário no início.
- A **seta de tendência** só existe para a leitura mais recente; as leituras do histórico da LibreLinkUp não a têm, por isso não mostram seta.

---

## 11. Limitações conhecidas

- **Interface só em português europeu** e **só mg/dL** (sem mmol/L).
- **Um único rácio para o dia todo** — não há rácios por hora do dia.
- **Com a app fechada à força, não há alarmes.** O iOS não deixa uma app de terceiros correr indefinidamente sem estar aberta; é por isso que não deves fechá-la.
- A **LibreLinkUp atrasa-se**: o valor "atual" pode chegar vários minutos depois do sensor, e o histórico às vezes ainda mais. "há X min" mostra sempre a hora real da medição.
- **Pedidos a mais bloqueiam a conta temporariamente.** Se carregares em "Testar ligação" muitas vezes seguidas, a LibreLinkUp responde "a limitar pedidos" durante alguns minutos. A app não insiste: volta a tentar só no ciclo normal de 5 minutos.
- A absorção de hidratos a 30 g/h e os atrasos de 15 min (hidratos) e 2 h (FPU) são **aproximações**, não valores da literatura para cada pessoa.

---

## 12. Privacidade

- **Tudo fica no iPhone.** Não há servidor, contas da app, nem analytics.
- A password da LibreLinkUp fica no **Keychain** do iPhone e só é enviada à LibreLinkUp.
- O histórico (leituras, refeições, doses, alarmes) fica numa base de dados local da app. Apagar a app apaga os dados.

---

## 13. Resolução de problemas

| Mensagem ou sintoma | O que fazer |
|---|---|
| "Email ou password da LibreLinkUp inválidos" | Confirma que é a conta de **seguidor** (passo 1) e não a do sensor. |
| "A LibreLinkUp pede uma ação na app oficial" | Abre a app LibreLinkUp com essa conta e aceita termos/política, ou confirma o email. |
| "Nenhuma ligação nesta conta" | O convite ainda não foi aceite na LibreLinkUp (passo 1.4). |
| "LibreLinkUp está a limitar pedidos" | Espera alguns minutos e não repitas o teste de ligação. |
| Aviso laranja "Sem ligação à LibreLinkUp" | O último pedido falhou. A mensagem por baixo diz porquê. A app volta a tentar sozinha a cada 5 min. |
| "Configura primeiro o teu perfil…" | *Ajustes → Rácios e alvos* → preencher → Guardar. |
| "Sem leitura recente do sensor" no Tratamento/Baixa | A última leitura tem mais de 15 min. Mede na ponta do dedo e introduz o valor. |
| "Guardar" não fica ativo em Rácios e alvos | Todos os campos têm de ter um número maior que 0, e o mínimo tem de ser menor que o máximo. |
| A app deixou de abrir ao fim de uma semana | Conta gratuita: carrega outra vez em ▶ no Xcode (secção 4.5). |
| O ▶ do Xcode fica encravado | Usa a instalação por linha de comandos (secção 4.5). |
| O alarme de baixa não tocou | A app estava fechada à força? O volume estava no mínimo? |

---

## 14. Para programadores

```
ios/
  Glucose/
    Engine/            DosingEngine.swift (bólus, resgate, alarmes), MedicalMath.swift (IOB, COB, FPU)
    Local/             LocalStore (SwiftData), PollingService (LibreLinkUp → base de dados → alarmes),
                       BackgroundScheduler (atualização em segundo plano)
    LibreLinkUpClient.swift   cliente da API da LibreLinkUp (regiões, termos, limite de pedidos)
    APIClient.swift    fachada única usada pelas Views
    AlarmManager.swift sons e alarme de ecrã inteiro (sessão de áudio em segundo plano)
    Views/             SwiftUI
  GlucoseEngineTests/  testes de paridade e das regras de alarme
engine.js, medicalMath.js   implementação de referência do motor (JavaScript), com as fontes documentadas
test/engine.test.js         testes do motor de referência
scripts/generate-parity-fixtures.js   gera os casos de teste de paridade a partir do engine.js
```

**Testes:**

```bash
# motor de referência (Node 18+)
npm test

# app iOS — paridade do motor de doses + regras de alarme
cd ios && xcodegen generate
xcodebuild -project Glucose.xcodeproj -scheme Glucose \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

**Paridade:** o motor de doses em Swift é um porte do `engine.js`. Os testes de paridade correm os mesmos 40 cenários nos dois e exigem resultados iguais. Se mudares a matemática do `engine.js` ou do `medicalMath.js`, regenera os casos com `npm run fixtures`. As regras de alarme divergem de propósito do `engine.js` e são testadas à parte (`AlarmRulesTests`).

**Traduções:** os textos no código estão em inglês e as traduções vivem em `ios/Glucose/Localizable.xcstrings` (e `InfoPlist.xcstrings` para o texto do pedido de notificações). Para acrescentar um idioma, abre o catálogo no Xcode, carrega em **+** e escolhe o idioma — o Xcode mostra todas as frases por traduzir. Textos novos no código (`Text("…")`, `String(localized: "…")`) entram no catálogo automaticamente quando compilas no Xcode.

**Contribuir:** a branch `main` está protegida — abre um pull request. Para bugs, abre um issue com o que fizeste, o que esperavas e o que aconteceu. **Nunca incluas emails, passwords, valores clínicos ou capturas com dados de saúde.**

---

## 15. Créditos e licença

- **[pylibrelinkup](https://github.com/robberwick/pylibrelinkup)** — referência do protocolo da LibreLinkUp (endpoints, cabeçalhos, regiões).
- **[OpenAPS / oref0](https://openaps.readthedocs.io)** e **[Loop](https://loopkit.github.io/loopdocs/)** — modelo exponencial de insulina ativa.
- **Método de Varsóvia** — Pankowska E. et al., *Diabetes Technology & Therapeutics*, 2012.
- **[xDrip4iOS](https://github.com/JohanDegraeve/xdripswift)** — a técnica de manter a app viva em segundo plano com áudio silencioso.

Licença **MIT** — ver [LICENSE](LICENSE). Sem garantias de qualquer tipo.

FreeStyle Libre, LibreLink, LibreLinkUp e LibreView são marcas da Abbott. Este projeto não tem qualquer ligação à Abbott.
