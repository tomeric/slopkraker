-- Everything the importer needs to know about one island's buildings, as one JSON object.
--
-- Sources: 3D BAG (TU Delft, CC BY 4.0) over BAG (Kadaster) for the parts and their roof
-- heights, OpenStreetMap (ODbL) for the labels and the roads. Read-only: this runs against
-- the sibling map app's database under PGOPTIONS=-c default_transaction_read_only=on.
--
-- Takes :cx :cy :radius -- the island's centre in RD (EPSG:28992) and how far around it to
-- look, in metres. The window's SHAPE is the whole reason a spike became an importer: the
-- neighbourhood polygon the spike used has the estate in it and the church in another.
--
-- A part's `eaves` and `ridge` come from the roof faces of the Pand's mesh that actually
-- sit over this part -- min and max z of the label-1 faces, against the part's own ground
-- height -- because a Pand's mesh covers all of its parts at once.
WITH win AS (SELECT ST_SetSRID(ST_MakePoint(:cx, :cy), 28992) AS c),
parts AS (
  SELECT b.id, b.source_id, split_part(b.source_id, '/', 1) AS pand, b.geom,
         ST_Area(b.geom) AS area, b.height, b.ground_height, b.roof_type, b.levels, b.year,
         ST_Area(b.geom) / NULLIF(ST_Area(ST_OrientedEnvelope(b.geom)), 0) AS rect,
         ST_SimplifyPreserveTopology(b.geom, 0.4) AS simple,
         ST_OrientedEnvelope(b.geom) AS env,
         ST_Distance(b.geom, win.c) AS dist
  FROM buildings b, win
  WHERE b.source = 'bag3d' AND ST_DWithin(b.geom, win.c, :radius)
),
-- `flat` is the face seen from above, and it is made valid rather than merely flattened.
-- A mesh face is a plane in space and nothing says its shadow is a simple polygon: the
-- church has a roof plane that folds across itself in plan, and a wall face flattens to a
-- line. GEOS refuses to intersect either -- "side location conflict", which fails the whole
-- import rather than that one face. Made valid, the fold becomes two polygons and the wall
-- becomes an empty one that the area guard below drops, which is what both already meant.
faces AS (
  SELECT m.bag_id, m.labels[d.path[1]] AS label, d.geom AS face,
         ST_CollectionExtract(ST_MakeValid(ST_Force2D(d.geom)), 3) AS flat
  FROM building_meshes m JOIN (SELECT DISTINCT pand FROM parts) p ON p.pand = m.bag_id, LATERAL ST_Dump(m.geom) d
),
part_roof AS (
  SELECT p.id,
         min(ST_ZMin(f.face)) - p.ground_height AS eaves,
         max(ST_ZMax(f.face)) - p.ground_height AS ridge,
         count(*) AS roof_faces
  FROM parts p JOIN faces f ON f.bag_id = p.pand AND f.label = 1
  WHERE ST_Area(f.flat) > 0.05 AND ST_Area(ST_Intersection(f.flat, p.geom)) > 0.5 * ST_Area(f.flat)
  GROUP BY p.id, p.ground_height
),
adj AS (
  SELECT p1.source_id AS a, p2.source_id AS b,
         ST_Length(ST_Intersection(ST_Boundary(p1.geom), ST_Buffer(p2.geom, 0.3))) AS shared
  FROM parts p1 JOIN buildings p2 ON p2.source = 'bag3d' AND p2.id <> p1.id AND ST_DWithin(p1.geom, p2.geom, 0.3)
),
osm AS (
  SELECT DISTINCT ON (p.pand) p.pand, o.kind
  FROM (SELECT pand, ST_Union(geom) AS geom FROM parts GROUP BY pand) p
  JOIN buildings o ON o.source = 'osm' AND ST_Intersects(o.geom, p.geom)
  ORDER BY p.pand, ST_Area(ST_Intersection(p.geom, o.geom)) DESC
),
roads AS (
  SELECT r.name, r.highway, r.width, ST_AsGeoJSON(r.geom)::json AS geom
  FROM roads r, win WHERE ST_DWithin(r.geom, win.c, :radius + 80)
)
SELECT json_build_object(
  'centre', json_build_array(:cx, :cy),
  'parts', (SELECT json_agg(json_build_object(
      'id', p.id, 'source_id', p.source_id, 'pand', p.pand,
      'area', round(p.area::numeric, 2), 'rect', round(p.rect::numeric, 3),
      'h70', round(p.height::numeric, 2), 'ground', round(p.ground_height::numeric, 2),
      'roof_type', p.roof_type, 'levels', p.levels, 'year', p.year, 'dist', round(p.dist::numeric, 1),
      'eaves', round(r.eaves::numeric, 2), 'ridge', round(r.ridge::numeric, 2), 'roof_faces', r.roof_faces,
      'osm', o.kind,
      'geom', ST_AsGeoJSON(p.geom)::json, 'simple', ST_AsGeoJSON(p.simple)::json, 'env', ST_AsGeoJSON(p.env)::json
    ) ORDER BY p.pand, p.source_id) FROM parts p LEFT JOIN part_roof r USING (id) LEFT JOIN osm o USING (pand)),
  'adjacency', (SELECT json_agg(json_build_object('a', a, 'b', b, 'shared', round(shared::numeric, 2)) ORDER BY a, b) FROM adj),
  'roads', (SELECT json_agg(json_build_object('name', name, 'highway', highway, 'width', width, 'geom', geom)) FROM roads)
);
