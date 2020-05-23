module NSWTopo
  module ArcGIS
    module Map
      TILE = 1000
      FIELD_TYPES = %W[esriFieldTypeOID esriFieldTypeInteger esriFieldTypeSmallInteger esriFieldTypeDouble esriFieldTypeSingle esriFieldTypeString esriFieldTypeGUID esriFieldTypeDate].to_set
      UNIQUE_TYPES = %W[esriFieldTypeInteger esriFieldTypeSmallInteger esriFieldTypeString].to_set
      NoUniqueFieldError = Class.new RuntimeError
      NoGeometryError = Class.new RuntimeError

      def prepare(where: nil, geometry: nil, unique: nil)
        @where = where
        @objectid_field = @layer["fields"].find do |field|
          field["type"] == "esriFieldTypeOID"
        end&.fetch("name")

        raise "ArcGIS layer does not support dynamic layers: #{@name}" unless @service["supportsDynamicLayers"]
        raise "ArcGIS layer does not support SVG output: #{@name}" unless @service["supportedImageFormatTypes"].split(?,).include? "SVG"
        raise "ArcGIS layer must have an objectid field: #{@name}" unless @objectid_field
        raise NoGeometryError, "ArcGIS layer does not support spatial filtering: #{@name}" if geometry

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
        @dynamic_layer = { source: { type: "mapLayer", mapLayerId: @id }, drawingInfo: { showLabels: false, renderer: renderer } }

        unique ||= @type_field
        unique ||= @layer.dig("drawingInfo", "renderer", "field1") if @layer.dig("drawingInfo", "renderer", "type") == "uniqueValue"
        raise NoUniqueFieldError unless unique

        classification_def = { type: "uniqueValueDef", uniqueValueFields: [unique,unique] }
        renderer = get_json "dynamicLayer/generateRenderer", layer: @dynamic_layer.to_json, classificationDef: classification_def.to_json

        @count = renderer["uniqueValueInfos"].sum do |info|
          info["count"]
        end
      end

      def pages(per_page)
        Enumerator.new do |yielder|
          table = Hash.new do |hash, objectid|
            hash[objectid] = { }
          end

          names_types = @layer["fields"].select do |field|
            FIELD_TYPES === field["type"]
          end.map do |field|
            [field["name"], field.values_at("name", "type")]
          end.to_h.values_at(*@fields)

          max, delimiters = 0, %w[| ~ ^]
          while table.length < @count
            min, max = max, max + 10000
            names_types.each_slice(2).yield_self do |pairs|
              pairs.any? ? pairs.map(&:transpose) : [[[],[]]]
            end.each do |names, types|
              paged_where = join_clauses "#{@objectid_field}>=#{min}", "#{@objectid_field}<#{max}", *@where
              classification_def = { type: "uniqueValueDef", uniqueValueFields: [@objectid_field, *names], fieldDelimiter: delimiters.first }
              response = get_json "dynamicLayer/generateRenderer", where: paged_where, layer: @dynamic_layer.to_json, classificationDef: classification_def.to_json
              rows = response["uniqueValueInfos"].map do |info|
                info["value"].split(delimiters.first).map(&:strip)
              end
              delimiters.rotate! and redo if rows.any? { |row| row.length > 1 + names.length }
              rows.each do |objectid, *values|
                properties = table[objectid.to_i]
                values.zip(types, names).each do |value, type, name|
                  properties[name] = case
                  when value == "<Null>" then nil
                  when value == "" then nil
                  when type == "esriFieldTypeOID" then Integer(value)
                  when type == "esriFieldTypeInteger" then Integer(value)
                  when type == "esriFieldTypeSmallInteger" then Integer(value)
                  when type == "esriFieldTypeDouble" then Float(value)
                  when type == "esriFieldTypeSingle" then Float(value)
                  when type == "esriFieldTypeString" then String(value)
                  when type == "esriFieldTypeGUID" then String(value)
                  when type == "esriFieldTypeDate" then String(value)
                  end
                rescue ArgumentError
                  raise "could not interpret #{value.inspect} as #{type}"
                end
              end
            end
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

          sets = table.group_by(&:last).map(&:last).sort_by(&:length)
          yielder << GeoJSON::Collection.new(projection: projection, name: @name) if sets.none?

          while objectids_properties = sets.shift
            while objectids_properties.any?
              begin
                objectids, properties = objectids_properties.take(per_page).transpose
                dynamic_layers = [@dynamic_layer.merge(definitionExpression: "#{@objectid_field} IN (#{objectids.join ?,})")]
                export = get_json "export", format: "svg", dynamicLayers: dynamic_layers.to_json, bbox: bbox, size: size, mapScale: scale, dpi: dpi
                href = URI.parse export["href"]
                xml = Connection.new(href).get(href.path, &:body)
                xmin, xmax, ymin, ymax = export["extent"].values_at "xmin", "xmax", "ymin", "ymax"
              rescue Connection::Error
                (per_page /= 2) > 0 ? retry : raise
              end

              features = REXML::Document.new(xml).elements.collect("svg//g[@transform]//g[@transform][path[@d]]") do |group|
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
                        if curve.values_at(0,-1).distance < 0.99 * curve.segments.map(&:distance).sum
                          reduced = 3.times.inject [ curve ] do |reduced|
                            reduced << reduced.last.each_cons(2).map do |(x0, y0), (x1, y1)|
                              [0.5 * (x0 + x1), 0.5 * (y0 + y1)]
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
                  next GeoJSON::Point.new point, properties
                when "esriGeometryPolyline"
                  next GeoJSON::LineString.new coords[0], properties if @mixed && coords.one?
                  next GeoJSON::MultiLineString.new coords, properties
                when "esriGeometryPolygon"
                  coords.each(&:reverse!) unless coords[0].anticlockwise?
                  polys = coords.slice_before(&:anticlockwise?).entries
                  next GeoJSON::Polygon.new polys.first, properties if @mixed && polys.one?
                  next GeoJSON::MultiPolygon.new polys, properties
                end
              end

              yielder << GeoJSON::Collection.new(projection: projection, name: @name, features: features)
              objectids_properties.shift per_page
            end
          end
        end
      end
    end
  end
end
