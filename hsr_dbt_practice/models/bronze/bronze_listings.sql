{#
{% set incremental_flag = 1 %}
{% set incremental_col = 'CREATED_AT' %}

SELECT * FROM {{ source('staging','listings') }}

{% if incremental_flag == 1 %}
    WHERE {{ incremental_col  }}  > (Select COALESCE(MAX({{ incremental_col }}) , '1900-01-01') from {{ this }})
{% endif %}
#}


{{ config(materialized = 'incremental') }}

SELECT * FROM {{ source('staging','listings') }}

{% if is_incremental() %}
  WHERE  CREATED_AT  > (select coalesce(max(CREATED_AT), '1900-01-01') from {{ this }})
{% endif %}