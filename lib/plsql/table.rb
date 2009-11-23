module PLSQL

  module TableClassMethods
    def find(schema, table)
      if schema.select_first(
            "SELECT table_name FROM all_tables
            WHERE owner = :owner
              AND table_name = :table_name",
            schema.schema_name, table.to_s.upcase)
        new(schema, table)
      # search for synonym
      elsif (row = schema.select_first(
            "SELECT t.owner, t.table_name
            FROM all_synonyms s, all_tables t
            WHERE s.owner IN (:owner, 'PUBLIC')
              AND s.synonym_name = :synonym_name
              AND t.owner = s.table_owner
              AND t.table_name = s.table_name
            ORDER BY DECODE(s.owner, 'PUBLIC', 1, 0)",
            schema.schema_name, table.to_s.upcase))
        new(schema, row[1], row[0])
      else
        nil
      end
    end
  end

  class Table
    extend TableClassMethods

    attr_reader :columns, :schema_name, :table_name

    def initialize(schema, table, override_schema_name = nil)
      @schema = schema
      @schema_name = override_schema_name || schema.schema_name
      @table_name = table.to_s.upcase
      @columns = {}

      @schema.connection.select_all("
        SELECT column_name, column_id position,
              data_type, data_length, data_precision, data_scale, char_used,
              data_type_owner, data_type_mod
        FROM all_tab_columns
        WHERE owner = :owner
        AND table_name = :table_name
        ORDER BY column_id",
        @schema_name, @table_name
      ) do |r|
        column_name, position,
              data_type, data_length, data_precision, data_scale, char_used,
              data_type_owner, data_type_mod = r
        @columns[column_name.downcase.to_sym] = {
          :position => position && position.to_i,
          :data_type => data_type_owner && 'OBJECT' || data_type,
          :data_length => data_type_owner ? nil : data_length && data_length.to_i,
          :data_precision => data_precision && data_precision.to_i,
          :data_scale => data_scale && data_scale.to_i,
          :char_used => char_used,
          :type_owner => data_type_owner,
          :type_name => data_type_owner && data_type,
          :sql_type_name => data_type_owner && "#{data_type_owner}.#{data_type}"
        }
      end
    end

    def select(first_or_all, sql_params='', *bindvars)
      case first_or_all
      when :first, :all
        select_sql = "SELECT * "
      when :count
        select_sql = "SELECT COUNT(*) "
      else
        raise ArgumentError, "Only :first, :all or :count are supported"
      end
      select_sql << "FROM \"#{@schema_name}\".\"#{@table_name}\" "
      case sql_params
      when String
        select_sql << sql_params
      when Hash
        raise ArgumentError, "Cannot specify bind variables when passing WHERE conditions as Hash" unless bindvars.empty?
        where_sqls = []
        order_by_sql = nil
        sql_params.each do |k,v|
          if k == :order_by
            order_by_sql = "ORDER BY #{v} "
          else
            where_sqls << "#{k} = :#{k}"
            bindvars << v
          end
        end
        select_sql << "WHERE " << where_sqls.join(' AND ') unless where_sqls.empty?
        select_sql << order_by_sql if order_by_sql
      else
        raise ArgumentError, "Only String or Hash can be provided as SQL condition argument"
      end
      if first_or_all == :count
        @schema.select_one(select_sql, *bindvars)
      else
        @schema.select(first_or_all, select_sql, *bindvars)
      end
    end

    def all(sql='', *bindvars)
      select(:all, sql, *bindvars)
    end

    def first(sql='', *bindvars)
      select(:first, sql, *bindvars)
    end

    def count(sql='', *bindvars)
      select(:count, sql, *bindvars)
    end

    def insert(record)
      # if Array of records is passed then insert each individually
      if record.is_a?(Array)
        record.each {|r| insert(r)}
        return nil
      end

      call = ProcedureCall.new(TableProcedure.new(@schema, self, :insert), [record])
      call.exec
    end

    def update(params)
      raise ArgumentError, "Only Hash parameter can be passed to table update method" unless params.is_a?(Hash)
      where = params.delete(:where)
      
      table_proc = TableProcedure.new(@schema, self, :update)
      table_proc.add_set_arguments(params)
      table_proc.add_where_arguments(where) if where
      call = ProcedureCall.new(table_proc, table_proc.argument_values)
      call.exec
    end

    def delete(sql_params='', *bindvars)
      delete_sql = "DELETE FROM \"#{@schema_name}\".\"#{@table_name}\" "
      case sql_params
      when String
        delete_sql << sql_params
      when Hash
        raise ArgumentError, "Cannot specify bind variables when passing WHERE conditions as Hash" unless bindvars.empty?
        where_sqls = []
        sql_params.each do |k,v|
          where_sqls << "#{k} = :#{k}"
          bindvars << v
        end
        delete_sql << "WHERE " << where_sqls.join(' AND ') unless where_sqls.empty?
      else
        raise ArgumentError, "Only String or Hash can be provided as SQL condition argument"
      end
      @schema.execute(delete_sql, *bindvars)
    end

    # wrapper class to simulate Procedure class for ProcedureClass#exec
    class TableProcedure
      attr_reader :arguments, :argument_list, :return, :out_list, :schema

      def initialize(schema, table, operation)
        @schema = schema
        @table = table
        @operation = operation

        @return = [nil]
        @out_list = [[]]

        case @operation
        when :insert
          @argument_list = [[:p_record]]
          @arguments = [{:p_record => {
            :data_type => 'PL/SQL RECORD',
            :fields => @table.columns
          }}]
        when :update
          @argument_list = [[]]
          @arguments = [{}]
          @set_sqls = []
          @set_values = []
          @where_sqls = []
          @where_values = []
        end
      end

      def overloaded?
        false
      end

      def procedure
        nil
      end

      def add_set_arguments(params)
        params.each do |k,v|
          raise ArgumentError, "Invalid column name #{k.inspect} specified as argument" unless (column_metadata = @table.columns[k])
          @argument_list[0] << k
          @arguments[0][k] = column_metadata
          @set_sqls << "#{k}=:#{k}"
          @set_values << v
        end
      end

      def add_where_arguments(params)
        case params
        when Hash
          params.each do |k,v|
            raise ArgumentError, "Invalid column name #{k.inspect} specified as argument" unless (column_metadata = @table.columns[k])
            @argument_list[0] << :"w_#{k}"
            @arguments[0][:"w_#{k}"] = column_metadata
            @where_sqls << "#{k}=:w_#{k}"
            @where_values << v
          end
        when String
          @where_sqls << params
        end
      end

      def argument_values
        @set_values + @where_values
      end

      def call_sql(params_string)
        case @operation
        when :insert
          "INSERT INTO \"#{@table.schema_name}\".\"#{@table.table_name}\" VALUES #{params_string};\n"
        when :update
          update_sql = "UPDATE \"#{@table.schema_name}\".\"#{@table.table_name}\" SET #{@set_sqls.join(', ')}"
          update_sql << " WHERE #{@where_sqls.join(' AND ')}" unless @where_sqls.empty?
          update_sql << ";\n"
          update_sql
        end
      end

    end

  end

end
