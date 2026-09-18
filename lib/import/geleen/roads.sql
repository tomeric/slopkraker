-- The drivable lines inside the world's bounds, as polylines in RD (EPSG:28992).
--
-- Takes :x0 :y0 :x1 :y1, the world's bounds converted back to survey coordinates. Roads
-- are clipped to the box and dumped, so a street that leaves and re-enters comes back as
-- two lines rather than one that jumps the gap; the client draws them as one ribbon on the
-- terrain, with no colliders, which is why a stray segment costs a triangle and not a lip.
--
-- Source: OpenStreetMap contributors (ODbL), via the sibling map app. Read-only.
WITH box AS (SELECT ST_MakeEnvelope(:x0, :y0, :x1, :y1, 28992) AS g)
SELECT json_agg(json_build_object('kind', r.highway, 'width', r.width, 'points', (
  SELECT json_agg(json_build_array(round(ST_X(p.geom)::numeric, 2), round(ST_Y(p.geom)::numeric, 2)) ORDER BY p.path)
  FROM ST_DumpPoints(g.geom) p)))
FROM roads r, box, LATERAL ST_Dump(ST_Intersection(r.geom, box.g)) g
WHERE ST_Intersects(r.geom, box.g) AND r.highway IN ('residential', 'living_street', 'tertiary', 'secondary', 'service', 'cycleway')
  AND GeometryType(g.geom) = 'LINESTRING';
