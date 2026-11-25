
-- EXPERIMENTO 1: FILTRO POR DATA
-- Consulta original: aplica ::date na coluna.

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id AS pedido_id, p.criado_em, p.observacoes,
       i.quantidade, i.preco_unitario_centavos
FROM pedidos p
JOIN itens_pedido i ON i.pedido_id = p.id
WHERE p.criado_em::date BETWEEN DATE '2024-01-01' AND DATE '2024-01-07'
  AND p.status <> 'cancelado';

-- Consulta reescrita: intervalo semiaberto que permite usar
-- o indice B-tree de criado_em.

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id AS pedido_id, p.criado_em, p.observacoes,
       i.quantidade, i.preco_unitario_centavos
FROM pedidos p
JOIN itens_pedido i ON i.pedido_id = p.id
WHERE p.criado_em >= TIMESTAMP '2024-01-01'
  AND p.criado_em < TIMESTAMP '2024-01-08'
  AND p.status <> 'cancelado';


-- EXPERIMENTO 2: PRODUTOS MAIS VENDIDOS
-- Soma unidades e receita por produto, ordenando pelos maiores valores.

EXPLAIN (ANALYZE, BUFFERS)
SELECT pr.id, pr.nome, pr.categoria,
       SUM(i.quantidade) AS unidades,
       SUM(i.quantidade * i.preco_unitario_centavos) AS receita_centavos
FROM itens_pedido i
JOIN pedidos p ON p.id = i.pedido_id
JOIN produtos pr ON pr.id = i.produto_id
WHERE p.status <> 'cancelado'
GROUP BY pr.id, pr.nome, pr.categoria
ORDER BY receita_centavos DESC, pr.id
LIMIT 10;


-- EXPERIMENTO 3: COMPARACAO ENTRE CONSULTA DETALHADA E AGRUPADA

-- Consulta detalhada: retorna uma linha por item de pedido.

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.id AS pedido_id, p.criado_em, p.observacoes,
       i.quantidade, i.preco_unitario_centavos
FROM pedidos p
JOIN itens_pedido i ON i.pedido_id = p.id
WHERE p.criado_em >= TIMESTAMP '2024-01-01'
  AND p.criado_em < TIMESTAMP '2024-01-08'
  AND p.status <> 'cancelado';

-- Consulta agrupada: calcula os totais diretamente no PostgreSQL.

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.criado_em::date AS dia,
       COUNT(DISTINCT p.id) AS pedidos,
       SUM(i.quantidade) AS itens,
       SUM(i.quantidade * i.preco_unitario_centavos) AS receita_centavos
FROM pedidos p
JOIN itens_pedido i ON i.pedido_id = p.id
WHERE p.criado_em >= TIMESTAMP '2024-01-01'
  AND p.criado_em < TIMESTAMP '2024-01-08'
  AND p.status <> 'cancelado'
GROUP BY p.criado_em::date
ORDER BY dia;

