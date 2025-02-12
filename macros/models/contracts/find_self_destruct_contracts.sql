{% macro find_self_destruct_contracts_by_chain( chain ) %}

SELECT
blockchain, created_time, created_block_number, creation_tx_hash, contract_address
  , destructed_time, destructed_block_number, destructed_tx_hash
FROM (

  SELECT
  blockchain, created_time, created_block_number, creation_tx_hash, contract_address
    , destructed_time, destructed_block_number, destructed_tx_hash
    , ROW_NUMBER() OVER (PARTITION BY blockchain, contract_address ORDER BY created_block_number DESC) as rn
  FROM (

    --self destruct method 1: same tx
    select
      '{{chain}}' as blockchain
      ,cr.block_time as created_time 
      ,cr.block_number as created_block_number
      ,cr.tx_hash as creation_tx_hash 
      ,cr.address as contract_address
      ,sd.block_time as destructed_time
      ,sd.block_number as destructed_block_number
      ,sd.tx_hash as destructed_tx_hash 
    from {{ source( chain , 'traces') }} as cr
    join {{ source( chain , 'traces') }} as sd
      on cr.tx_hash = sd.tx_hash
      and cr.block_time = sd.block_time
      AND cr.block_number = sd.block_number
      and (sd.address = cr.address OR sd.address IS NULL) -- handle for if the destruct has a null address, but make sure we don't mis-map
      and   (CASE WHEN cardinality(cr.trace_address) = 0 then cast(-1 as bigint) else cr.trace_address[1] end)
          = (CASE WHEN cardinality(sd.trace_address) = 0 then cast(-1 as bigint) else sd.trace_address[1] end)
      and sd.type = 'suicide'
      {% if is_incremental() %}
      and sd.block_time >= date_trunc('day', now() - interval '7' day)
      and cr.address NOT IN (SELECT contract_address FROM {{this}} ) --ensure no duplicates
      {% endif %}

    WHERE 1=1 --cr.blockchain = '{{chain}}'
      AND cr.type = 'create'
      {% if is_incremental() %}
      and cr.block_time >= date_trunc('day', now() - interval '7' day) --we know same tx
      {% endif %}
    group by 1, 2, 3, 4, 5, 6, 7, 8

    UNION ALL

    --self destruct method 2: later tx
    select
      '{{chain}}' as blockchain
      ,cr.block_time as created_time 
      ,cr.block_number ascreated_block_number
      ,cr.tx_hash as creation_tx_hash 
      ,cr.address as contract_address 
      ,sds.block_time as destructed_time
      ,sds.block_number as destructed_block_number
      ,sds.tx_hash as destructed_tx_hash 

    from {{ source( chain , 'creation_traces') }} as cr
    JOIN {{ source( chain , 'traces') }} as sds
      ON cr.address = sds.address
      AND cr.block_time <= sds.block_time
      AND cr.block_number <= sds.block_number
      AND sds.type = 'suicide'
      AND sds.address IS NOT NULL
      {% if is_incremental() %}
      and sds.block_time >= date_trunc('day', now() - interval '7' day)
      and cr.address NOT IN (SELECT contract_address FROM {{this}} th WHERE th.blockchain = '{{chain}}' ) --ensure no duplicates
      {% endif %}

    WHERE 1=1 --cr.blockchain = '{{chain}}'
      -- no incremental check on creates, since we've seen destructs happen as long as 100 days later.
    group by 1, 2, 3, 4, 5, 6, 7, 8

  ) inter

) a 
WHERE rn = 1

{% endmacro %}