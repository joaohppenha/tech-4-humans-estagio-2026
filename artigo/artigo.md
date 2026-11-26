# Investigação de Desempenho em uma API Node.js com PostgreSQL: Análise de Hipóteses, Consultas SQL e Resultados sob Carga Concorrente

## Resumo

Este artigo investiga gargalos de desempenho em uma aplicação de comércio eletrônico composta por uma API Node.js/Express e um banco de dados PostgreSQL 16. A investigação analisa o comportamento da aplicação sob carga concorrente, examina consultas SQL e compara intervenções relacionadas à criação de índices e à redução de consultas repetidas.

O ambiente experimental utiliza dados sintéticos determinísticos, compostos por 100 mil clientes, 20 mil produtos, 500 mil pedidos e 1,5 milhão de itens de pedido. Os testes de carga foram realizados com 20 usuários virtuais durante 60 segundos, em três execuções por cenário. Conforme a metodologia documentada no repositório, a comparação considera a mediana das execuções.

Na linha de base, o throughput mediano foi de aproximadamente 2,73 requisições por segundo, com mediana de latência de 1.501,7 ms e p95 de 23.153,6 ms. No cenário com índices, o throughput chegou a 7,19 req/s, a mediana de latência caiu para 563,2 ms e o p95 para 9.916,3 ms. Na etapa posterior, que incluiu a refatoração de uma rota com padrão N+1, o throughput mediano foi de 7,29 req/s e a mediana de latência de 530 ms. Entretanto, o p95 aumentou para 11.027,2 ms em relação ao cenário somente com índices.

Experimentos adicionais com `EXPLAIN (ANALYZE, BUFFERS)` demonstraram que a reformulação de um filtro temporal permitiu o aproveitamento de um índice existente. Também foi investigada a agregação de dados diretamente no PostgreSQL: embora o tamanho da representação JSON calculada tenha diminuído substancialmente, o tempo de execução SQL não apresentou melhora no teste realizado.

Os resultados mostram que algumas hipóteses foram confirmadas, outras parcialmente confirmadas e outras permaneceram sem comprovação. A principal conclusão é que a redução do número de consultas, a utilização de índices e a diminuição do volume de dados retornados são propriedades relevantes, mas seus efeitos sobre o desempenho precisam ser avaliados separadamente e com medições adequadas.

**Palavras-chave:** Node.js; PostgreSQL; desempenho; índices; consultas N+1; planos de execução; otimização SQL.

---

## 1. Introdução

O desempenho de aplicações web que utilizam bancos de dados relacionais depende de diferentes fatores, entre eles a estrutura das consultas, a organização dos dados, os índices disponíveis, a quantidade de operações executadas e a concorrência de acesso.

Em aplicações que realizam diversas operações de leitura, consultas repetidas podem aumentar o tempo de resposta e o custo de comunicação entre a aplicação e o banco. Da mesma forma, filtros construídos de maneira inadequada podem impedir que o sistema de gerenciamento de banco de dados utilize índices disponíveis.

Este trabalho investiga uma aplicação de comércio eletrônico desenvolvida com Node.js, Express e PostgreSQL 16. O objetivo não é apenas aplicar técnicas de otimização, mas verificar se os problemas inicialmente identificados explicam o comportamento observado e se as intervenções produzem os efeitos esperados.

A investigação foi orientada pelas seguintes questões:

1. A ausência de índices adequados contribui para planos de execução ineficientes?
2. A rota de consulta dos pedidos de um cliente apresenta o padrão N+1?
3. A substituição de consultas repetidas por uma consulta com `JOIN` melhora o desempenho geral da aplicação?
4. A agregação diretamente no PostgreSQL reduz o tempo de execução e o volume de dados retornados?
5. Quais hipóteses não foram confirmadas e quais alternativas ainda precisam ser investigadas?

A contribuição deste trabalho está na análise crítica dos resultados. Uma alteração pode melhorar a estrutura de uma consulta sem necessariamente produzir ganhos uniformes em todas as métricas da aplicação. Por isso, as conclusões distinguem mudanças observadas no código, resultados medidos e hipóteses ainda não comprovadas.

## 2. Aplicação e ambiente experimental

### 2.1 Arquitetura

A aplicação é composta por:

- API desenvolvida em Node.js e Express;
- banco de dados PostgreSQL 16;
- comunicação com o banco por meio do pacote `pg`;
- ambiente de execução baseado em contêineres Docker;
- testes de carga realizados com k6.

A implementação examinada em `api/src/db.js` utiliza a classe `Client` do pacote `pg`. A função de consulta instancia um cliente, estabelece uma conexão, executa o comando SQL e encerra a conexão.

Portanto, a implementação examinada não utiliza um pool de conexões (`Pool`). Essa característica é importante para a investigação, pois consultas repetidas também implicam repetição do ciclo de abertura e encerramento de conexões.

### 2.2 Dados utilizados

O banco foi preenchido com dados sintéticos e determinísticos. As quantidades principais são:

| Entidade | Registros |
|---|---:|
| Clientes | 100.000 |
| Produtos | 20.000 |
| Pedidos | 500.000 |
| Itens de pedido | 1.500.000 |

Os scripts de geração permitem reproduzir a mesma estrutura de dados em novas instalações. Os registros não representam pessoas reais.

A distribuição sintética permite repetir os experimentos, mas impõe uma limitação: os resultados dependem das características dessa distribuição e não devem ser generalizados automaticamente para qualquer aplicação de comércio eletrônico.

### 2.3 Limites de infraestrutura

Os limites configurados no ambiente foram:

| Serviço | CPU | Memória |
|---|---:|---:|
| API | 0,5 CPU | 256 MB |
| PostgreSQL | 1 CPU | 512 MB |

Esses limites fazem parte das condições em que os resultados foram obtidos. Alterações de infraestrutura podem modificar o comportamento observado.

## 3. Fundamentação teórica

### 3.1 Índices e planos de execução

Índices são estruturas auxiliares utilizadas pelo SGBD para localizar registros sem necessariamente percorrer todas as páginas de uma tabela. O PostgreSQL oferece diferentes métodos de indexação, entre eles B-tree, GIN, GiST e BRIN.

O índice B-tree é adequado para diversas operações de igualdade, ordenação e comparação por intervalos. Entretanto, sua utilização depende da estrutura da consulta, da seletividade dos filtros, das estatísticas disponíveis e da estimativa de custos realizada pelo otimizador.

A documentação do PostgreSQL destaca que índices possuem custos de armazenamento e manutenção. Por isso, a criação de índices deve ser orientada pelas consultas efetivamente executadas, e não pela simples presença de uma coluna em uma cláusula SQL (POSTGRESQL GLOBAL DEVELOPMENT GROUP, 2024a).

A ferramenta `EXPLAIN` apresenta o plano de execução escolhido pelo PostgreSQL. Com `ANALYZE`, a consulta é executada e são apresentados tempos e quantidades reais de linhas. A opção `BUFFERS` acrescenta informações sobre os blocos acessados durante a execução.

A interpretação de um plano deve considerar o conjunto de operações, a quantidade de registros processados, a seletividade dos filtros, os métodos de junção e o custo total. Uma varredura sequencial (`Seq Scan`) não representa necessariamente um problema: em consultas que precisam ler uma parcela grande da tabela, ela pode ser mais econômica do que acessar os registros por meio de um índice (POSTGRESQL GLOBAL DEVELOPMENT GROUP, 2024b).

### 3.2 Consultas N+1

O padrão N+1 ocorre quando uma consulta inicial recupera um conjunto de registros e, em seguida, a aplicação executa consultas adicionais para cada registro encontrado.

Essa estratégia pode multiplicar a quantidade de interações com o banco conforme o volume de dados aumenta. Turcotte, Aldrich e Tip (2022) investigaram a identificação e a refatoração automatizada desse problema em aplicações que utilizam bancos de dados.

Uma alternativa é utilizar operações relacionais, como `JOIN`, para recuperar informações relacionadas em uma consulta. Contudo, a redução do número de consultas não garante, isoladamente, uma melhoria de todas as métricas. O volume de dados, a complexidade da consulta e o processamento realizado pela aplicação também influenciam o resultado.

### 3.3 Concorrência e Event Loop no Node.js

O Node.js utiliza um modelo orientado a eventos, no qual o Event Loop coordena a execução de callbacks e operações assíncronas. A documentação oficial alerta que operações computacionalmente pesadas executadas no Event Loop podem atrasar o atendimento de outras requisições (OPENJS FOUNDATION, s.d.).

Entretanto, a existência de consultas sequenciais com `await` não comprova, por si só, bloqueio do Event Loop. É necessário distinguir o tempo de espera por operações de I/O do tempo de processamento síncrono executado pelo JavaScript.

Por essa razão, a investigação considera o custo das consultas repetidas e do estabelecimento de conexões, sem atribuir automaticamente o gargalo ao bloqueio do Event Loop.

## 4. Hipóteses iniciais

A investigação começou com duas hipóteses principais.

### 4.1 H1 — Índices inadequados

A primeira hipótese era que a ausência de índices em colunas utilizadas em filtros e relacionamentos aumentava o custo de determinadas consultas.

Foram considerados os seguintes atributos:

- `clientes.lower(email)`;
- `pedidos.cliente_id`;
- `pedidos.status`;
- `pedidos.criado_em`;
- `itens_pedido.pedido_id`;
- `itens_pedido.produto_id`.

A hipótese previa que índices adequados poderiam reduzir o custo de consultas seletivas e permitir planos de execução mais eficientes.

### 4.2 H2 — Consultas repetidas na rota de pedidos

A segunda hipótese estava relacionada à rota histórica `GET /clientes/:id/pedidos`.

Na implementação original, o fluxo executava:

1. Uma consulta para verificar a existência do cliente.
2. Uma consulta para recuperar os pedidos.
3. Uma consulta para recuperar os itens de cada pedido.
4. Uma consulta para recuperar os produtos associados a cada item.

Considerando `P` como a quantidade de pedidos e `I` como a quantidade de itens retornados, a quantidade de consultas era:

$$ Q_{\text{original}} = 2 + P + I $$


A hipótese era que essa repetição aumentava o custo de comunicação com o banco e o tempo total de atendimento da requisição.

A alternativa investigada utilizou uma consulta com `LEFT JOIN`, mantendo a verificação de existência do cliente e agrupando os resultados na aplicação:

$$
Q_{\text{refatorada}} = 2
$$

A redução da quantidade de consultas é uma propriedade estrutural da refatoração. A hipótese adicional de melhoria geral de desempenho precisaria ser confirmada pelos testes.

## 5. Metodologia

### 5.1 Testes de carga

Os testes de carga utilizaram k6 com:

- 20 usuários virtuais;
- 60 segundos de duração;
- aquecimento de 15 segundos;
- semente 42;
- três execuções por cenário.

O README do repositório orienta a comparação pela mediana das três execuções, e não por uma execução isolada. Também alerta que a variação entre execuções pode ultrapassar 30% e que percentis por rota podem ser pouco confiáveis quando poucas requisições são realizadas durante o teste.

Foram analisadas as seguintes métricas:

- throughput, em requisições por segundo;
- mediana da latência;
- p95 da latência;
- p99 da latência, quando disponível;
- planos de execução SQL;
- quantidade de linhas retornadas;
- buffers acessados pelo PostgreSQL.

### 5.2 Experimentos SQL

Além dos testes de carga, foram executadas consultas diretamente no PostgreSQL utilizando:

```sql
EXPLAIN (ANALYZE, BUFFERS)
```

Esses experimentos permitiram examinar os planos de execução, comparar filtros e observar a utilização de índices.

As medições adicionais foram exploratórias. Não constituem uma nova bateria controlada de três execuções por consulta. Por isso, seus tempos são apresentados como observações pontuais, e não como resultados estatísticos equivalentes aos testes de carga.

### 5.3 Rastreabilidade

Os cenários de carga foram registrados no histórico do repositório. Entre os commits associados à evolução da investigação estão:

| Commit | Papel na investigação |
|---|---|
| `cf8effd` | Linha de base |
| `ee539a1` | Etapa de índices |
| `bbb819f` | Etapa de refatoração N+1 |
| `5d0761d` | Registro posterior da investigação SQL e dos testes HTTP |

O commit `5d0761d` também registra os arquivos de investigação exploratória em `resultados/20261125-172900-investigacao-sql/`.

A identificação do commit é importante para relacionar cada resultado à versão de código correspondente. Resultados de versões históricas não devem ser confundidos com o comportamento da versão atual da API.

## 6. Resultados dos testes de carga

### 6.1 Comparação dos cenários

A tabela apresenta os valores medianos apurados para as três execuções de cada cenário:

| Cenário | Throughput | Mediana da latência | p95 | p99 |
|---|---:|---:|---:|---:|
| Linha de base | 2,73 req/s | 1.501,7 ms | 23.153,6 ms | 26.780,2 ms |
| Com índices | 7,19 req/s | 563,2 ms | 9.916,3 ms | 19.195,4 ms |
| API refatorada | 7,29 req/s | 530 ms | 11.027,2 ms | 19.941,4 ms |

A introdução dos índices esteve associada a um aumento de aproximadamente 163% no throughput mediano em relação à linha de base.

A mediana da latência caiu aproximadamente 62,5%, passando de 1.501,7 ms para 563,2 ms. O p95 caiu aproximadamente 57,2%.

Esses resultados sustentam a hipótese de que as alterações de indexação contribuíram para melhorar o desempenho geral no cenário avaliado.

Entretanto, a comparação entre o cenário com índices e a etapa posterior de refatoração apresenta um resultado diferente.

O throughput passou de 7,19 para 7,29 req/s, uma diferença aproximada de 1,4%. A mediana da latência caiu de 563,2 para 530 ms, redução aproximada de 5,9%. Por outro lado, o p95 aumentou de 9.916,3 para 11.027,2 ms, piora aproximada de 11,2%. O p99 também aumentou de 19.195,4 para 19.941,4 ms.

Portanto, não é possível afirmar que a refatoração da rota N+1 produziu uma melhoria geral e consistente em todas as métricas.

A interpretação mais adequada é que a indexação esteve associada à maior mudança observada no teste de carga. A refatoração reduziu a quantidade de consultas da rota investigada, mas seu benefício adicional não foi demonstrado de maneira uniforme no conjunto de requisições.

### 6.2 Interpretação dos percentis

A mediana representa o valor central das observações e é menos sensível a valores extremos do que a média.

O p95 representa o limite abaixo do qual se encontram 95% das observações. Assim, ele ajuda a examinar a experiência das requisições mais lentas.

A redução da mediana não implica necessariamente redução proporcional do p95 ou do p99. No cenário refatorado, a mediana melhorou em relação ao cenário somente com índices, enquanto os percentis superiores pioraram.

Essa diferença é relevante: uma otimização pode beneficiar o comportamento típico sem melhorar a cauda de latência.

Além disso, o período de 60 segundos e a distribuição de requisições por rota limitam a precisão de percentis calculados sobre poucas amostras. Por esse motivo, os percentis devem ser interpretados dentro das condições específicas do experimento.

## 7. Experimentos SQL adicionais

### 7.1 Filtro temporal e utilização de índice

Uma consulta histórica do relatório de vendas utilizava a seguinte condição:

```sql
WHERE p.criado_em::date BETWEEN
      DATE '2024-01-01' AND DATE '2024-01-07'
```

A conversão `::date` era aplicada diretamente à coluna `criado_em`. O plano observado apresentou `Parallel Seq Scan` sobre a tabela de pedidos.

Foi testada uma reformulação utilizando intervalo semiaberto:

```sql
WHERE p.criado_em >= TIMESTAMP '2024-01-01'
  AND p.criado_em < TIMESTAMP '2024-01-08'
```

Com essa alteração, o plano passou a utilizar `Bitmap Index Scan` sobre o índice `idx_pedidos_criado_em`, seguido de leitura das páginas correspondentes.

As duas consultas retornaram 12.945 linhas no período analisado.

Os tempos observados foram:

| Condição | Primeira execução observada | Execução posterior |
|---|---:|---:|
| Filtro com `::date` | aproximadamente 8.186 ms | aproximadamente 644–730 ms |
| Intervalo semiaberto | aproximadamente 248 ms | aproximadamente 38 ms |

A diferença entre a primeira execução e as posteriores evidencia a influência das condições de cache. Portanto, esses tempos não devem ser apresentados como uma comparação controlada de desempenho.

A evidência mais consistente é a mudança do plano de execução: a consulta reformulada passou a utilizar o índice existente, enquanto a condição original provocava varredura sequencial.

Esse experimento confirma que a forma de escrever o filtro temporal pode influenciar a possibilidade de utilização de um índice B-tree.

### 7.2 Consulta de produtos mais vendidos

Também foi investigada uma consulta que calcula unidades vendidas e receita por produto, relacionando pedidos, itens de pedido e produtos.

O plano observado apresentou:

- `Parallel Seq Scan` em `itens_pedido`;
- `Parallel Seq Scan` em `pedidos`;
- operações de `Hash Join`;
- agregação com `HashAggregate`;
- ordenação final com `top-N heapsort`.

Os tempos observados foram aproximadamente 2.877 ms e 2.737 ms em duas execuções.

A consulta produziu 19.206 grupos antes da seleção dos dez primeiros resultados.

Alguns índices existentes, como `idx_itens_pedido_pedido_id`, `idx_itens_pedido_produto_id` e `idx_pedidos_status`, não foram utilizados nesse plano.

Isso não significa que os índices estejam incorretos. A consulta processa uma parcela expressiva das tabelas, e o filtro `status <> 'cancelado'` elimina somente cerca de 10% dos pedidos. Nesse contexto, uma varredura sequencial paralela pode ser mais econômica do que acessar muitos registros por meio de índices.

O `LIMIT 10` também não elimina a necessidade de calcular os grupos, pois a ordenação depende dos valores agregados.

O resultado demonstra que a hipótese de que os índices eliminariam varreduras sequenciais em todas as consultas não foi confirmada. A escolha do plano depende do padrão de acesso e da seletividade dos filtros.

### 7.3 Agregação no PostgreSQL

Foi investigada a possibilidade de transferir para o PostgreSQL o agrupamento que uma implementação histórica realizava na aplicação.

A consulta detalhada retornou 12.945 linhas. A consulta agrupada por dia retornou sete linhas.

A comparação pontual apresentou:

| Consulta | Linhas retornadas | Tempo observado |
|---|---:|---:|
| Detalhada | 12.945 | 34,453 ms |
| Agrupada | 7 | 38,093 ms |

A consulta agrupada foi aproximadamente 10,6% mais lenta nessa comparação.

Portanto, a hipótese de que a agregação diretamente no banco reduziria o tempo de execução SQL não foi confirmada pelo experimento.

Entretanto, também foi calculado o tamanho das representações JSON produzidas no PostgreSQL:

| Estrutura | Tamanho calculado |
|---|---:|
| Detalhada | 5.138.162 bytes |
| Agrupada | 558 bytes |

A redução aproximada foi de 99,99%.

Essa diferença precisa ser interpretada com cuidado. As estruturas não preservam a mesma quantidade de informação: a resposta detalhada apresenta campos de cada item, enquanto a agrupada apresenta totais por dia.

Além disso, o tamanho foi calculado a partir de representações JSON no PostgreSQL. Não corresponde a uma captura direta do corpo HTTP transmitido pela API.

A conclusão é que a agregação reduziu o tamanho da representação calculada, mas não demonstrou menor tempo de execução SQL no teste realizado.

### 7.4 Precisão numérica no Node.js

Outro experimento verificou o comportamento dos valores agregados retornados pelo pacote `pg`.

No PostgreSQL, `SUM(integer)` retorna `BIGINT`. Por padrão, o driver `pg` representa valores desse tipo como strings no JavaScript.

No conjunto de dados analisado, foram observados:

| Campo | Tipo recebido no Node.js | Valor |
|---|---|---:|
| Quantidade total de itens | string | 2.999.999 |
| Receita total em centavos | string | 738.359.727.310 |

O valor da receita, quando convertido para `Number`, permanece dentro do intervalo de inteiros seguros do JavaScript.

Isso não garante segurança para valores arbitrariamente maiores. Se o volume financeiro crescer, a conversão deverá ser reavaliada para evitar perda de precisão.

O experimento evidencia que a otimização de consultas também exige atenção à representação dos tipos numéricos entre o PostgreSQL e a aplicação.

## 8. Testes HTTP e compatibilidade

Foram realizados testes HTTP manuais na API em execução.

Os resultados registrados em `resultados/20261125-172900-investigacao-sql/http-manual.txt` incluem:

| Requisição | Resultado observado |
|---|---|
| `GET /saude` | 200 — `{"status":"ok"}` |
| `GET /clientes/1/pedidos` | 200 — pedidos e itens retornados |
| `GET /clientes/999999/pedidos` | 404 — cliente não encontrado |
| `GET /clientes/abc/pedidos` | 400 — ID inválido |
| `GET /clientes/0/pedidos` | 400 — ID inválido |
| `GET /clientes/11` | 404 — rota não encontrada |
| `GET /clientes/999999` | 404 — rota não encontrada |

A resposta 404 de `GET /clientes/11` não demonstra que o cliente não existe no banco. Essa rota individual não está implementada na versão atual examinada da API.

O projeto também possui um verificador de contrato com 42 casos fixos de requisição. Esses casos verificam respostas esperadas, incluindo códigos HTTP e corpos JSON. Eles não representam 42 rotas distintas nem comprovam o comportamento para todas as entradas possíveis.

Os testes manuais complementam o verificador automatizado, mas não substituem uma bateria abrangente de testes funcionais.

## 9. Discussão das hipóteses

Os resultados permitem classificar as hipóteses em três grupos.

### 9.1 Hipóteses confirmadas

**Utilização inadequada do filtro temporal:** a consulta que aplicava `::date` sobre a coluna provocava varredura sequencial. A reformulação para intervalo semiaberto permitiu utilizar o índice existente.

**Existência do padrão N+1:** a implementação histórica da rota de pedidos executava consultas adicionais para cada pedido e item. A refatoração reduziu a quantidade de consultas de `2 + P + I` para duas.

### 9.2 Hipóteses parcialmente confirmadas

**Benefício dos índices:** o cenário com índices apresentou melhora expressiva nas métricas gerais em comparação com a linha de base. Entretanto, não foi demonstrado que todos os índices criados contribuíram igualmente para o resultado. A consulta de produtos mais vendidos continuou utilizando varreduras sequenciais.

**Benefício da refatoração N+1:** a redução de consultas foi confirmada estruturalmente. Entretanto, o ganho adicional nas métricas gerais foi pequeno e não uniforme. O p95 e o p99 pioraram em relação ao cenário somente com índices.

### 9.3 Hipóteses não confirmadas

**Agregação SQL mais rápida:** a consulta agrupada retornou menos linhas, mas foi ligeiramente mais lenta no experimento pontual. A hipótese de redução do tempo de execução SQL não foi confirmada.

**Saturação de pool de conexões:** a implementação examinada não utiliza um pool. Ela cria e encerra conexões individuais. O custo desse ciclo é uma hipótese plausível, mas seu impacto isolado não foi medido.

**Bloqueio do Event Loop:** não foi realizada instrumentação específica para demonstrar que o Event Loop era o gargalo. A existência de operações assíncronas sequenciais não é evidência suficiente para essa conclusão.

### 9.4 Como tratar hipóteses que não se confirmam

Uma hipótese não confirmada não deve ser transformada em uma conclusão positiva apenas porque a técnica utilizada é conhecida.

No caso da agregação SQL, o resultado indica que reduzir a quantidade de linhas retornadas não garante menor tempo de execução no banco. Um próximo experimento deveria medir separadamente o tempo SQL, a serialização, o tamanho efetivo do corpo HTTP e o tempo total da requisição.

No caso da refatoração N+1, seria necessário isolar a rota em um teste de carga específico, controlar a quantidade de pedidos e itens por cliente e comparar o tempo total, o número de conexões e a quantidade de consultas executadas.

No caso das conexões, a implementação de um pool poderia ser avaliada em um experimento separado, comparando diferentes tamanhos de pool e níveis de concorrência.

Essa abordagem evita transformar uma expectativa técnica em uma conclusão sem evidência.

## 10. Limitações da investigação

### 10.1 Dados sintéticos

Os dados são determinísticos e reproduzíveis, mas não representam necessariamente a distribuição de dados, a cardinalidade ou a concorrência de um ambiente real.

### 10.2 Quantidade de execuções

Os testes de carga foram realizados em três execuções por cenário. A mediana reduz a influência de uma execução atípica, mas três repetições ainda representam uma amostra limitada.

### 10.3 Percentis por rota

O período de 60 segundos pode gerar poucas observações para determinadas rotas. Por isso, p95 e p99 por rota podem ser instáveis.

### 10.4 Experimentos SQL exploratórios

Os experimentos adicionais com `EXPLAIN` foram pontuais e não constituem uma bateria estatística de três repetições com alternância controlada entre cache frio e aquecido.

### 10.5 Divergência entre versões do repositório

A versão atual examinada da API contém as rotas de saúde, listagem de clientes e consulta de pedidos por cliente. O README descreve um conjunto mais amplo de funcionalidades, e o histórico do Git contém implementações anteriores de relatórios.

A consulta histórica de vendas por dia foi recuperada de um commit anterior (`94e9199`). Ela buscava linhas detalhadas e realizava a agregação em JavaScript com `Map` e `Set`. Os experimentos SQL adicionais foram executados diretamente no PostgreSQL, utilizando consultas recuperadas desse histórico, e não por chamadas HTTP a uma rota de relatório existente na versão atual.

Essa distinção é necessária para que o artigo não atribua à versão atual funcionalidades que pertencem ao histórico do projeto.

### 10.6 Medições de recursos

Alguns valores resumidos de CPU e memória apresentaram divergências em relação aos arquivos CSV brutos. Por esse motivo, esses valores não são utilizados como evidência conclusiva neste artigo.

A ausência desses números evita apresentar uma comparação de recursos que não esteja suficientemente reconciliada com os dados originais.

## 11. Trabalhos futuros

Os experimentos indicam caminhos que podem ser investigados em trabalhos posteriores.

### 11.1 Pool de conexões

A implementação de `pg.Pool` poderia reduzir o custo de estabelecer e encerrar uma conexão para cada consulta. O efeito precisaria ser medido em diferentes níveis de concorrência e tamanhos de pool.

### 11.2 Índices para busca textual

Consultas com padrões como `ILIKE '%termo%'` podem exigir estratégias diferentes de B-tree. Uma possibilidade é investigar índices GIN ou GiST com a extensão `pg_trgm`.

### 11.3 Índices compostos e parciais

A combinação de colunas em índices deve ser orientada pelas consultas reais. Também é necessário avaliar sobreposição entre índices e o custo de manutenção durante inserções e atualizações.

### 11.4 Visões materializadas e tabelas de resumo

Relatórios executados frequentemente poderiam utilizar dados pré-agregados. Essa abordagem pode reduzir o custo de consultas analíticas, mas exige uma estratégia de atualização e controle de defasagem dos dados.

### 11.5 Cache

Uma solução como Redis poderia reduzir o custo de relatórios repetidos, desde que a frequência de leitura, a taxa de atualização e a política de invalidação justificassem a complexidade adicional.

### 11.6 Particionamento

O particionamento de pedidos por data poderia ser investigado em conjuntos de dados maiores, especialmente para consultas históricas. Os experimentos atuais não demonstram que essa estratégia seja necessária.

### 11.7 Instrumentação do Node.js

A medição específica do Event Loop, do tempo de espera por conexões e do tempo de processamento no JavaScript permitiria separar melhor os custos da aplicação e do banco.

Essas alternativas são possibilidades de investigação. Sua eficácia não foi demonstrada neste trabalho.

## 12. Conclusão

A investigação identificou gargalos associados à forma de acesso aos dados e à repetição de consultas na aplicação.

A introdução de índices esteve associada à maior melhoria observada nos testes gerais de carga. O throughput mediano passou de 2,73 para 7,19 req/s, enquanto a mediana da latência caiu de 1.501,7 ms para 563,2 ms.

A análise dos planos de execução demonstrou que a reformulação de um filtro temporal permitiu utilizar um índice existente. Por outro lado, a consulta de produtos mais vendidos continuou utilizando varreduras sequenciais, mostrando que a presença de índices não garante sua utilização em todas as consultas.

A refatoração da rota N+1 reduziu estruturalmente a quantidade de consultas, mas não apresentou melhoria uniforme nas métricas gerais. A agregação SQL reduziu o tamanho da representação JSON calculada, porém não apresentou menor tempo de execução no experimento pontual.

Esses resultados reforçam que a otimização de desempenho exige mais do que aplicar técnicas conhecidas. É necessário formular hipóteses, definir experimentos capazes de testá-las, interpretar resultados contrários às expectativas e reconhecer as limitações das medições.

Como continuidade, recomenda-se isolar a medição da rota N+1, avaliar o uso de pool de conexões, investigar índices especializados para consultas textuais e medir estratégias de pré-agregação para relatórios.

A principal conclusão é que uma otimização deve ser considerada comprovada apenas na dimensão efetivamente medida. Reduzir consultas, alterar planos de execução ou diminuir o volume de uma representação são resultados relevantes, mas não substituem a avaliação do comportamento completo da aplicação sob carga.

## Referências

OPENJS FOUNDATION. **Don't Block the Event Loop (or the Worker Pool)**. Node.js Learn. Disponível em: https://nodejs.org/learn/asynchronous-work/dont-block-the-event-loop. Acesso em: 25 nov. 2026.

POSTGRESQL GLOBAL DEVELOPMENT GROUP. **PostgreSQL 16 Documentation: Chapter 11 — Indexes**. 2024a. Disponível em: https://www.postgresql.org/docs/16/indexes.html. Acesso em: 25 nov. 2026.

POSTGRESQL GLOBAL DEVELOPMENT GROUP. **PostgreSQL 16 Documentation: Using EXPLAIN**. 2024b. Disponível em: https://www.postgresql.org/docs/16/using-explain.html. Acesso em: 25 nov. 2026.

RAMAKRISHNAN, Raghu; GEHRKE, Johannes. **Database Management Systems**. 3. ed. Boston: McGraw-Hill, 2003.

TURCOTTE, Alexi; ALDRICH, Mark W.; TIP, Frank. **Reformulator: Automated Refactoring of the N+1 Problem in Database-Backed Applications**. In: *Proceedings of the 37th IEEE/ACM International Conference on Automated Software Engineering (ASE '22)*. 2022. DOI: https://doi.org/10.1145/3551349.3556911.

YAN, Cong; CHEUNG, Alvin; YANG, Junwen; LU, Shan. **Understanding Database Performance Inefficiencies in Real-world Web Applications**. In: *Proceedings of the 2017 ACM Conference on Information and Knowledge Management (CIKM '17)*. 2017. p. 1299–1308. DOI: https://doi.org/10.1145/3132847.3132954.

## Declaração de uso de inteligência artificial

Ferramentas de inteligência artificial generativa foram utilizadas como apoio à organização da investigação, análise de consultas SQL e revisão textual. Também auxiliaram na investigação de resultados errôneos e inconsistências ocultas da versão anterior e  da estruturação de testes adicionais, ajudando a ampliar o escopo da Pesquisa
