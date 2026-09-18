-- One row per Pand in the island window, with the cheap geometry Game::Import::Classifier
-- scores: footprint area, tallest part, rectangularity of the outline, slenderness of the
-- most slender part, floor count, how many Pand it touches, and the OSM label by largest
-- overlap.
--
-- Takes :cx :cy :radius. The spike windowed this by the Geleen-Noord neighbourhood polygon;
-- the church island lies in a different neighbourhood, so the window is a circle about the
-- island's centre like window.sql's and rows.sql's -- on the CENTROID, so a Pand belongs to
-- exactly one island rather than to both by overlapping their rims.
--
-- Sources: 3D BAG (TU Delft, CC BY 4.0) over BAG (Kadaster), labels from OpenStreetMap
-- (ODbL). Read-only.
WITH win AS (SELECT ST_SetSRID(ST_MakePoint(:cx, :cy), 28992) AS c),
parts AS (
  SELECT b.id, b.source_id, split_part(b.source_id, '/', 1) AS pand, b.geom,
         ST_Area(b.geom) AS area, b.height, b.ground_height, b.roof_type, b.levels, b.year,
         ST_Area(b.geom) / NULLIF(ST_Area(ST_OrientedEnvelope(b.geom)), 0) AS rect,
         ST_NPoints(ST_SimplifyPreserveTopology(b.geom, 0.4)) - 1 AS verts
  FROM buildings b, win
  WHERE b.source = 'bag3d' AND ST_DWithin(ST_Centroid(b.geom), win.c, :radius)
),
pand_geom AS (SELECT pand, ST_Union(geom) AS geom FROM parts GROUP BY pand),
adj AS (
  SELECT p1.pand AS a, split_part(p2.source_id, '/', 1) AS b
  FROM parts p1
  JOIN buildings p2 ON p2.source = 'bag3d' AND p2.geom && ST_Expand(p1.geom, 0.3) AND ST_DWithin(p1.geom, p2.geom, 0.3)
  WHERE split_part(p2.source_id, '/', 1) <> p1.pand
  GROUP BY 1, 2
),
neighbours AS (SELECT a AS pand, count(*) AS n FROM adj GROUP BY a),
osm AS (
  SELECT DISTINCT ON (pg.pand) pg.pand, o.kind, ST_Area(ST_Intersection(pg.geom, o.geom)) AS overlap
  FROM pand_geom pg
  JOIN buildings o ON o.source = 'osm' AND o.geom && pg.geom AND ST_Intersects(o.geom, pg.geom)
  ORDER BY pg.pand, ST_Area(ST_Intersection(pg.geom, o.geom)) DESC
),
agg AS (
  SELECT p.pand, count(*) AS n_parts, sum(p.area) AS area, max(p.height) AS h_max, min(p.height) AS h_min,
         (array_agg(p.area ORDER BY p.area DESC))[1] AS main_area,
         (array_agg(p.height ORDER BY p.area DESC))[1] AS main_h,
         (array_agg(p.rect ORDER BY p.area DESC))[1] AS main_rect,
         max(p.height / sqrt(NULLIF(p.area, 0))) AS slenderness,
         bool_or(p.area < 30 AND p.height > 12) AS has_tower,
         max(p.roof_type) AS roof_type, max(p.levels) AS levels, max(p.year) AS year, max(p.ground_height) AS ground
  FROM parts p GROUP BY p.pand
)
SELECT json_agg(json_build_object(
  'pand', a.pand, 'n_parts', a.n_parts, 'area', round(a.area::numeric, 1), 'main_area', round(a.main_area::numeric, 1),
  'h_max', round(a.h_max::numeric, 1), 'h_min', round(a.h_min::numeric, 1), 'main_h', round(a.main_h::numeric, 1),
  'main_rect', round(a.main_rect::numeric, 2),
  'union_rect', round((ST_Area(g.geom) / NULLIF(ST_Area(ST_OrientedEnvelope(g.geom)), 0))::numeric, 2),
  'union_verts', ST_NPoints(ST_SimplifyPreserveTopology(g.geom, 0.4)) - ST_NumGeometries(g.geom),
  'slenderness', round(a.slenderness::numeric, 2), 'has_tower', a.has_tower,
  'roof_type', a.roof_type, 'levels', a.levels, 'year', a.year, 'ground', round(a.ground::numeric, 2),
  'neighbours', coalesce(n.n, 0), 'osm', o.kind, 'osm_overlap', round(coalesce(o.overlap, 0)::numeric, 1),
  'cx', round(ST_X(ST_Centroid(g.geom))::numeric, 1), 'cy', round(ST_Y(ST_Centroid(g.geom))::numeric, 1)
))
FROM agg a JOIN pand_geom g USING (pand) LEFT JOIN neighbours n USING (pand) LEFT JOIN osm o USING (pand);
