const express = require('express');
const { consultar } = require('./db');

const rotas = express.Router();

const STATUS_VALIDOS = ['pago', 'entregue', 'cancelado', 'pendente'];
const TAMANHO_PAGINA = 20;
const MAX_DIAS_RELATORIO = 31;

function inteiroPositivo(valor) {
  if (typeof valor !== 'string' || !/^\d+$/.test(valor)) return null;
  const numero = Number(valor);
  return numero > 0 && Number.isSafeInteger(numero) ? numero : null;
}

function dataValida(valor) {
  if (typeof valor !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(valor)) return null;
  const data = new Date(`${valor}T00:00:00Z`);
  return !Number.isNaN(data.getTime()) && data.toISOString().slice(0, 10) === valor ? data : null;
}

function assincrono(manipulador) {
  return (req, res, next) => manipulador(req, res).catch(next);
}

function formatarCliente(linha) {
  return {
    id: linha.id,
    nome: linha.nome,
    email: linha.email,
    cidade: linha.cidade,
    criado_em: linha.criado_em,
  };
}

rotas.get('/saude', (req, res) => {
  res.json({ status: 'ok' });
});

rotas.get('/clientes', assincrono(async (req, res) => {
  const email = req.query.email;
  if (typeof email !== 'string' || email.trim() === '') {
    return res.status(400).json({ erro: 'informe o parametro email' });
  }

  const linhas = await consultar(
    'SELECT * FROM clientes WHERE lower(email) = lower($1) ORDER BY id',
    [email.trim()],
  );
  res.json(linhas.map(formatarCliente));
}));

rotas.get('/clientes/:id/pedidos', assincrono(async (req, res) => {
  const id = inteiroPositivo(req.params.id);
  if (id === null) return res.status(400).json({ erro: 'id invalido' });

  // 1. Verifica se o cliente existe primeiro
  const clientes = await consultar('SELECT * FROM clientes WHERE id = $1', [id]);
  if (clientes.length === 0) return res.status(404).json({ erro: 'cliente nao encontrado' });

  // 2. Consulta unificada com JOIN e agregação JSON (Elimina o N+1 queries)
  const linhas = await consultar(
    `SELECT 
        p.id AS pedido_id,
        p.status,
        p.criado_em,
        i.id AS item_id,
        i.quantidade,
        i.preco_unitario_centavos,
        pr.id AS produto_id,
        pr.nome AS produto_nome
     FROM pedidos p
     LEFT JOIN itens_pedido i ON i.pedido_id = p.id
     LEFT JOIN produtos pr ON pr.id = i.produto_id
     WHERE p.cliente_id = $1
     ORDER BY p.criado_em DESC, p.id DESC, i.id ASC`,
    [id],
  );

  // 3. Agrupa os resultados em memória de forma limpa e eficiente
  const pedidosMap = new Map();

  for (const linha of linhas) {
    if (!linha.pedido_id) continue;

    if (!pedidosMap.has(linha.pedido_id)) {
      pedidosMap.set(linha.pedido_id, {
        id: linha.pedido_id,
        status: linha.status,
        criado_em: linha.criado_em,
        total_centavos: 0,
        itens: [],
      });
    }

    const pedido = pedidosMap.get(linha.pedido_id);

    if (linha.item_id) {
      pedido.itens.push({
        produto_id: linha.produto_id,
        produto_nome: linha.produto_nome,
        quantidade: linha.quantidade,
        preco_unitario_centavos: linha.preco_unitario_centavos,
      });
      pedido.total_centavos += linha.quantidade * linha.preco_unitario_centavos;
    }
  }

  res.json(Array.from(pedidosMap.values()));
}));