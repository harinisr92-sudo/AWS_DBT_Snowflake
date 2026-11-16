{% macro tag(column_name) %}
{#      {% if column_name < 100  %}
         low
      {% elif column_name < 200 %}
         medium
      {% else %}
         high
      {% endif %}
#}
      CASE
          WHEN {{ column_name }} < 100 THEN 'low'
         WHEN {{ column_name }} < 200 THEN 'medium'
         ELSE 'high'
      END
{% endmacro %}