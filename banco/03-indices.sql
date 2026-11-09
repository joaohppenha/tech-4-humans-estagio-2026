-- Criação de índices para eliminar Sequential Scans e acelerar JOINs e buscas

-- 1. Busca de clientes por e-mail (case-insensitive)
CREATE INDEX IF NOT EXISTS idx_clientes_lower_email ON clientes (lower(email));

-- 2. Chaves estrangeiras e filtros na tabela pedidos
CREATE INDEX IF NOT EXISTS idx_pedidos_cliente_id ON pedidos (cliente_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_status ON pedidos (status);
CREATE INDEX IF NOT EXISTS idx_pedidos_criado_em ON pedidos (criado_em DESC);

-- Índice composto para acelerar relatórios por período e status (ex: vendas-por-dia)
CREATE INDEX IF NOT EXISTS idx_pedidos_status_criado_em ON pedidos (status, criado_em);

-- 3. Chaves estrangeiras na tabela itens_pedido para acelerar JOINs com pedidos e produtos
CREATE INDEX IF NOT EXISTS idx_itens_pedido_pedido_id ON itens_pedido (pedido_id);
CREATE INDEX IF NOT EXISTS idx_itens_pedido_produto_id ON itens_pedido (produto_id);