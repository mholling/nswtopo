module NSWTopo
  module ArcGIS
    module Map
      TILE = 1000
      NoUniqueFieldError = Class.new RuntimeError

      def pages(per_page)
        objectid_field = @layer["fields"].find do |field|
          field["type"] == "esriFieldTypeOID"
        end&.fetch("name")

        raise "ArcGIS layer does not support dynamic layers: #{@name}" unless @service["supportsDynamicLayers"]
        raise "ArcGIS layer does not support SVG output: #{@name}" unless @service["supportedImageFormatTypes"].split(?,).include? "SVG"
        raise "ArcGIS layer does not have an objectid field: #{@name}" unless objectid_field

        @unique ||= @type_field
        @unique ||= @layer["fields"].find do |field|
          field.values_at("name", "alias").map(&:downcase).include? @layer.dig("drawingInfo", "renderer", "field1")&.downcase
        end&.fetch("name")
        @unique ||= @coded_values.min_by do |name, lookup|
          lookup.length
        end&.first
        raise NoUniqueFieldError unless @unique

        @count = classify(@unique).sum(&:last)
        return [GeoJSON::Collection.new(projection: projection, name: @name)].each if @count.zero?

        @fields ||= @layer["fields"].select do |field|
          Layer::FIELD_TYPES === field["type"]
        end.map do |field|
          field["name"]
        end

        include_objectid = @fields.include? objectid_field
        min, chunk, table = 0, 10000, {}
        loop do
          break unless table.length < @count
          page, where = {}, ["#{objectid_field}>=#{min}", "#{objectid_field}<#{min + chunk}", *@where]
          Set[*@fields, *extra_field].delete(objectid_field).each_slice(2) do |fields|
            classify(objectid_field, *fields, where: where).each do |attributes, count|
              objectid = attributes.delete objectid_field
              page[objectid] ||= include_objectid ? { objectid_field => objectid } : {}
              page[objectid].merge! attributes
            end
          end
        rescue Connection::Error
          (chunk /= 2) > 0 ? retry : raise
        else
          table.merge! page
          min += chunk
        end

        parent = @layer
        scale = loop do
          break parent["minScale"] if parent["minScale"]&.nonzero?
          break parent["effectiveMinScale"] if parent["effectiveMinScale"]&.nonzero?
          break unless parent_id = parent.dig("parentLayer", "id")
          parent = get_json parent_id
        end || begin
          case @service["units"]
          when "esriMeters" then 100000
          else raise "can't get features from layer: #{@name}"
          end
        end

        bounds = @layer["extent"].values_at("xmin", "xmax", "ymin", "ymax").each_slice(2)
        cx, cy = bounds.map { |bound| 0.5 * bound.sum }
        bbox, size = %W[#{cx},#{cy},#{cx},#{cy} #{TILE},#{TILE}]
        dpi = bounds.map { |b0, b1| 0.0254 * TILE * scale / (b1 - b0) }.min * 0.999

        renderer = case @geometry_type
        when "esriGeometryPoint"
          { type: "simple", symbol: { color: [0,0,0,255], size: 1, type: "esriSMS", style: "esriSMSSquare" } }
        when "esriGeometryPolyline"
          { type: "simple", symbol: { color: [0,0,0,255], width: 1, type: "esriSLS", style: "esriSLSSolid" } }
        when "esriGeometryPolygon"
          { type: "simple", symbol: { color: [0,0,0,255], width: 0, type: "esriSFS", style: "esriSFSSolid" } }
        else
          raise "unsupported ArcGIS geometry type: #{@geometry_type}"
        end
        dynamic_layer = { source: { type: "mapLayer", mapLayerId: @id }, drawingInfo: { showLabels: false, renderer: renderer } }

        sets = table.group_by(&:last).map(&:last).sort_by(&:length)

        Enumerator::Lazy.new(sets) do |yielder, objectids_properties|
          while objectids_properties.any?
            begin
              objectids, properties = objectids_properties.take(per_page).transpose
              dynamic_layers = [dynamic_layer.merge(definitionExpression: "#{objectid_field} IN (#{objectids.join ?,})")]
              export = get_json "export", format: "svg", dynamicLayers: dynamic_layers.to_json, bbox: bbox, size: size, mapScale: scale, dpi: dpi
              href = URI.parse export["href"]
              xml = Connection.new(href).get(href.path, &:body)
              xmin, xmax, ymin, ymax = export["extent"].values_at "xmin", "xmax", "ymin", "ymax"
            rescue Connection::Error
              (per_page /= 2) > 0 ? retry : raise
            end

            REXML::Document.new(xml).elements.collect("svg//g[@transform]//g[@transform][path[@d]]") do |group|
              a, b, c, d, e, f = group.attributes["transform"].match(/matrix\((.*)\)/)[1].split(?\s).map(&:to_f)
              coords = []
              group.elements["path[@d]"].attributes["d"].gsub(/\ *([MmZzLlHhVvCcSsQqTtAa])\ */) do
                ?\s + $1 + ?\s
              end.strip.split(?\s).slice_before(/[MmZzLlHhVvCcSsQqTtAa]/).each do |command, *numbers|
                raise "can't handle SVG path data command: #{command}" unless numbers.length.even?
                coordinates = numbers.each_slice(2).map do |x, y|
                  fx, fy = [(a * Float(x) + c * Float(y) + e) / TILE, (b * Float(x) + d * Float(y) + f) / TILE]
                  [fx * xmax + (1 - fx) * xmin, fy * ymin + (1 - fy) * ymax]
                end
                case command
                when ?Z then next
                when ?M then coords << coordinates
                when ?L then coords.last.concat coordinates
                when ?C
                  coordinates.each_slice(3) do |points|
                    raise "unexpected SVG response (bad path data)" unless points.length == 3
                    curves = [[coords.last.last, *points]]
                    while curve = curves.shift
                      next if curve.first == curve.last
                      curve_length = curve.each_cons(2).sum do |v0, v1|
                        (v1 - v0).norm
                      end
                      if (curve.first - curve.last).norm < 0.99 * curve_length
                        reduced = 3.times.inject [ curve ] do |reduced|
                          reduced << reduced.last.each_cons(2).map do |p0, p1|
                            (p0 + p1) / 2
                          end
                        end
                        curves.unshift reduced.map(&:last).reverse
                        curves.unshift reduced.map(&:first)
                      else
                        coords.last << curve.last
                      end
                    end
                  end
                else raise "can't handle SVG path data command: #{command}"
                end
              end
              coords
            end.tap do |coords|
              lengths = [properties.length, coords.length]
              raise "unexpected SVG response (expected %i features, received %i)" % lengths if lengths.inject(&:<)
            end.zip(properties).map do |coords, properties|
              case @geometry_type
              when "esriGeometryPoint"
                raise "unexpected SVG response (bad point symbol)" unless coords.map(&:length) == [ 4 ]
                point = coords[0].transpose.map { |coords| coords.sum / coords.length }
                next GeoJSON::Point[point, properties]
              when "esriGeometryPolyline"
                next GeoJSON::LineString[coords[0], properties] if @mixed && coords.one?
                next GeoJSON::MultiLineString[coords, properties]
              when "esriGeometryPolygon"
                polys = GeoJSON::MultiLineString[coords.map(&:reverse), properties].to_multipolygon
                next @mixed && polys.one? ? polys.first : polys
              end
            end.tap do |features|
              yielder << GeoJSON::Collection.new(projection: projection, name: @name, features: features)
            end
            objectids_properties.shift per_page
          end
        end
      end
    end
  end
end
