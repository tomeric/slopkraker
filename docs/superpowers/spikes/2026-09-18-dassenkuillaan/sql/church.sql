WITH parts AS (
  SELECT b.id, b.source_id, split_part(b.source_id, '/', 1) AS pand, b.geom,
         ST_Area(b.geom) AS area, b.height, b.ground_height, b.roof_type, b.levels, b.year,
         ST_Area(b.geom) / NULLIF(ST_Area(ST_OrientedEnvelope(b.geom)), 0) AS rect,
         ST_SimplifyPreserveTopology(b.geom, 0.5) AS simple, ST_OrientedEnvelope(b.geom) AS env
  FROM buildings b WHERE b.source = 'bag3d' AND split_part(b.source_id, '/', 1) = ANY(:'pands')
),
faces AS (
  SELECT m.bag_id, m.labels[d.path[1]] AS label, d.geom AS face, ST_Force2D(d.geom) AS flat
  FROM building_meshes m JOIN (SELECT DISTINCT pand FROM parts) p ON p.pand = m.bag_id, LATERAL ST_Dump(m.geom) d
),
part_roof AS (
  SELECT p.id, min(ST_ZMin(f.face)) - p.ground_height AS eaves, max(ST_ZMax(f.face)) - p.ground_height AS ridge, count(*) AS roof_faces
  FROM parts p JOIN faces f ON f.bag_id = p.pand AND f.label = 1
  WHERE ST_Area(f.flat) > 0.05 AND ST_Area(ST_Intersection(f.flat, p.geom)) > 0.5 * ST_Area(f.flat)
  GROUP BY p.id, p.ground_height
)
SELECT json_agg(json_build_object(
  'id', p.id, 'source_id', p.source_id, 'pand', p.pand, 'area', round(p.area::numeric, 1), 'rect', round(p.rect::numeric, 2),
  'h70', round(p.height::numeric, 2), 'ground', round(p.ground_height::numeric, 2), 'roof_type', p.roof_type, 'levels', p.levels, 'year', p.year,
  'eaves', round(r.eaves::numeric, 2), 'ridge', round(r.ridge::numeric, 2), 'roof_faces', r.roof_faces,
  'geom', ST_AsGeoJSON(p.geom)::json, 'simple', ST_AsGeoJSON(p.simple)::json, 'env', ST_AsGeoJSON(p.env)::json
) ORDER BY p.pand, p.source_id) FROM parts p LEFT JOIN part_roof r USING (id);
