-- Rows of attached dwellings in the window, clustered by touching MAIN parts.
-- The main part of a Pand is its largest part taller than 4 m, or its largest part.
WITH win AS (SELECT ST_SetSRID(ST_MakePoint(186330, 332234), 28992) AS c),
parts AS (
  SELECT b.id, b.source_id, split_part(b.source_id, '/', 1) AS pand, b.geom, ST_Area(b.geom) AS area, b.height,
         row_number() OVER (PARTITION BY split_part(b.source_id, '/', 1) ORDER BY (b.height > 4.0) DESC, ST_Area(b.geom) DESC) AS rank
  FROM buildings b, win WHERE b.source = 'bag3d' AND ST_DWithin(b.geom, win.c, 50)
),
mains AS (
  SELECT *, ST_ClusterDBSCAN(geom, eps := 0.3, minpoints := 1) OVER () AS cluster FROM parts WHERE rank = 1
),
clusters AS (
  SELECT m.cluster,
         array_agg(m.pand ORDER BY m.pand) AS pands,
         array_agg(m.id ORDER BY m.pand) AS main_ids,
         ST_Union(m.geom) AS mains_geom
  FROM mains m GROUP BY m.cluster
),
everything AS (
  -- Buffered out and back in, so a hairline gap between two parts of one row does not split the union.
  SELECT c.cluster, ST_Buffer(ST_Union(ST_Buffer(p.geom, 0.2, 'join=mitre')), -0.2, 'join=mitre') AS geom
  FROM clusters c JOIN parts p ON p.pand = ANY(c.pands) GROUP BY c.cluster
)
SELECT json_agg(json_build_object(
  'cluster', c.cluster, 'pands', c.pands, 'main_ids', c.main_ids,
  'mains_rect', round((ST_Area(c.mains_geom) / NULLIF(ST_Area(ST_OrientedEnvelope(c.mains_geom)), 0))::numeric, 3),
  'envelope', ST_AsGeoJSON(ST_OrientedEnvelope(c.mains_geom))::json,
  'union', ST_AsGeoJSON(ST_SimplifyPreserveTopology(
      CASE WHEN ST_NumGeometries(e.geom) > 1
           THEN (SELECT d.geom FROM ST_Dump(e.geom) d ORDER BY ST_Area(d.geom) DESC LIMIT 1)
           ELSE e.geom END, 0.3))::json,
  'union_parts', ST_NumGeometries(e.geom)
) ORDER BY c.cluster) FROM clusters c JOIN everything e USING (cluster);
