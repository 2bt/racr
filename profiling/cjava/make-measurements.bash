#!/bin/bash

# This program and the accompanying materials are made available under the
# terms of the MIT license (X11 license) which accompanies this distribution.

# author: C. Bürger (based on the 'run.py' Python script of M. Tasić)

old_pwd=`pwd`

# Persist configuration in a script such that the measurements can be rerun:
echo "cd ../.." > rerun-measurements.bash
echo "./make-measurements.bash << EOF" >> rerun-measurements.bash

# Function always called when the script terminates:
my_exit(){
	# Ensure, the temporary rerun script is always deleted:
	cd $old_pwd
	rm rerun-measurements.bash
	exit 0
}
trap 'my_exit' 1 2 3 9 15

check_parameter(){
	read -r -p "$1" choice # No message printed on terminal if non-interactive. Thus,...
	if [ ! -t 0 ] # ...check if stdin is terminal? (test -t 0 == tty -s). If not...
	then
		echo "$1$choice" # ...print the read input.
	fi
	if [[ ! $choice =~ ^[1-9][0-9]*$ ]]
	then
		echo "ERROR: No integer number > 0 entered!"
		my_exit
	else
		eval $2=$choice
	fi
	echo $choice >> $old_pwd/rerun-measurements.bash
}

check_decision(){
	read -r -n1 -p "$1" choice
	if [ ! -t 0 ]
	then
		printf "$1$choice"
	fi
	echo ""
	case $choice in
		[y]* ) eval $2=$choice;;
		[n]* ) :;;
		* ) echo "ERROR: No valid choice entered!"; my_exit;;
	esac
	printf $choice >> $old_pwd/rerun-measurements.bash
}

check_abort(){
	check_decision "$1 Abort? (y/n): " abort
	if [ -n "$abort" ]
	then
		echo " !!! ABORTED !!!"
		my_exit
	fi
}

declare -a composition_modes=( never once always )
declare -a composition_systems=( Larceny Petite Racket Java_d Java_i Java_ic )

echo "=========================================>>> Create ComSysPE Measurements:"

# Query measurement parameters:
check_parameter "Max. execution time (s) : " maxtime
check_parameter "Number of hooks         : " hooks
check_parameter "Number of rewrites      : " rewrites
check_parameter "Rewrite step size       : " stepsize
for mode in ${composition_modes[@]}
do
	check_decision "Composition mode $mode	: " $mode
done
for system in ${composition_systems[@]}
do
	check_decision "$system			: " $system
done
echo ""

# Check plausibility of parameters:
if (( (rewrites % stepsize) != 0 ))
then
	check_abort "WARNING: Number of rewrites not multiple of step size!"
fi
if (( (depth % stepsize) != 0 ))
then
	check_abort "WARNING: Depth not multiple of step size!"
fi
echo ""

# Create directories:
mkdir -p $old_pwd/measurements/fragments
mkdir -p $old_pwd/measurements/recipes
measurement_dir=$old_pwd/measurements/`date "+%Y-%m-%d_%H-%M-%S"`
mkdir -p $measurement_dir/result-fragments

# Finish & copy the rerun script:
echo "" >> rerun-measurements.bash
echo "EOF" >> rerun-measurements.bash
chmod +x rerun-measurements.bash
cp -p rerun-measurements.bash $measurement_dir

# Generate target & source fragments:
cd $old_pwd/measurements/fragments
if [ ! -f Targets-h$hooks-r$i.cjava ]
then
	for (( i = stepsize; i <= rewrites; i = i + stepsize ))
	do
		echo "public class Targets {" > Targets-h$hooks-r$i.cjava
		echo "	public static class InnerA {" >> Targets-h$hooks-r$i.cjava
		echo "		public static int field1;" >> Targets-h$hooks-r$i.cjava
		echo "		public static int field2;" >> Targets-h$hooks-r$i.cjava
		echo "		public static class InnerB {" >> Targets-h$hooks-r$i.cjava
		echo "			public static int field1;" >> Targets-h$hooks-r$i.cjava
		echo "			public static int field2;" >> Targets-h$hooks-r$i.cjava
		echo "		}" >> Targets-h$hooks-r$i.cjava
		echo "	}" >> Targets-h$hooks-r$i.cjava
		for (( h = 1; h <= hooks; h++ ))
		do
			echo "	[[classhook$h]]" >> Targets-h$hooks-r$i.cjava
		done
		echo "}" >> Targets-h$hooks-r$i.cjava
		
		echo "public class Sources {" > Sources-h$hooks-r$i.cjava
		for (( h = 1; h <= hooks; h++ ))
		do
			echo "	public static class Source$h {" >> Sources-h$hooks-r$i.cjava
			echo "		public static int field1;" >> Sources-h$hooks-r$i.cjava
			echo "		public static void method(int a, int b) {" >> Sources-h$hooks-r$i.cjava
			echo "			Targets.InnerA.InnerB.field1 = a;" >> Sources-h$hooks-r$i.cjava
			echo "			Targets.InnerA.InnerB.field2 = b;" >> Sources-h$hooks-r$i.cjava
			if (( h > 1 ))
			then
				printf "			Targets." >> Sources-h$hooks-r$i.cjava
				depth=$(( i / hooks ))
				for (( j = 1; j <= depth; j++))
				do
					printf "Source%i." $(( h - 1 )) >> Sources-h$hooks-r$i.cjava
				done
				echo "field1 = b;" >> Sources-h$hooks-r$i.cjava
			fi
			echo "		}" >> Sources-h$hooks-r$i.cjava
			echo "		[[classhook$h]]" >> Sources-h$hooks-r$i.cjava
			echo "	}" >> Sources-h$hooks-r$i.cjava
		done
		echo "}" >> Sources-h$hooks-r$i.cjava
	done
fi

# Generate recipes:
cd $old_pwd/measurements/recipes
for (( i = stepsize; i <= rewrites; i = i + stepsize ))
do
	if [ ! -f h$hooks-r$i.cjava-recipe ]
	then
		printf "" > h$hooks-r$i.cjava-recipe
		if (( hooks > i ))
		then
			for (( j = 1; j <= rewrites; j++ ))
			do
				echo "bind Targets.*0.classhook$j Sources.**.Source$j;" >> h$hooks-r$i.cjava-recipe
			done
		else
			depth=$(( i / hooks ))
			for (( j = 1; i >= j * depth; j++ ))
			do
				echo "bind Targets.*"$(( depth - 1 ))".classhook$j Sources.**.Source$j;" >> h$hooks-r$i.cjava-recipe
			done
			rest=$(( i % hooks ))
			if (( rest > 0 ))
			then
				echo "bind Targets.*"$(( depth - 1 + rest ))".classhook1 Sources.**.Source1;" >> h$hooks-r$i.cjava-recipe
			fi
		fi
	fi
done

# Perform measurements:

aborted=( )
measure(){
	if [ "`echo ${aborted[@]} | grep $system-$mode-h$hooks`" != "" ]
	then
		echo " ABORTED"
		return
	fi
	error_file=$measurement_dir/result-fragments/$system-$mode-h$hooks-r$i-errors.txt
	start=`date +"%s"`
	$* &> $error_file
	elapsed=$(( `date +"%s"` - start ))
	if [ -s $error_file ]
	then
		rm $targets
		rm $sources
		echo " ERROR"
	else
		rm $error_file
		if [ ! -e $measurement_dir/measurements.table ]
		then
			echo "  System  |   Mode   |   Hooks  | Rewrites |   Time   " > $measurement_dir/measurements.table
			echo "----------+----------+----------+----------+----------" >> $measurement_dir/measurements.table
		fi
		printf " %-8s | %-8s | %8i | %8i | %8i \n" \
			$system $mode $hooks $i $elapsed >> $measurement_dir/measurements.table
		echo " ${elapsed}s"
		if (( $elapsed > maxtime ))
		then
			aborted+=( $system-$mode-h$hooks )
		fi
	fi
}

for (( i = stepsize; i <= rewrites; i = i + stepsize ))
do
	echo "$i:"
	for mode in ${composition_modes[@]}
	do
		if [ -n "${!mode}" ]
		then
			for system in ${composition_systems[@]}
			do
				if [ -n "${!system}" ]
				then
					printf "	$system-$mode	:"
					recipe=$old_pwd/measurements/recipes/h$hooks-r$i.cjava-recipe
					targets=$measurement_dir/result-fragments/Targets-$system-$mode-h$hooks-r$i.cjava
					sources=$measurement_dir/result-fragments/Sources-$system-$mode-h$hooks-r$i.cjava
					cp $old_pwd/measurements/fragments/Targets-h$hooks-r$i.cjava $targets
					cp $old_pwd/measurements/fragments/Sources-h$hooks-r$i.cjava $sources
					case $system in
					Larceny)
						measure larceny --r6rs --path "$old_pwd/cjava-racr/larceny-bin:$old_pwd/../../racr/larceny-bin" \
							--program $old_pwd/run-cjava-compiler.scm -- $mode $recipe $targets $sources;;
					Petite)
						measure petite --libdirs "$old_pwd:$old_pwd/../.." \
							--program $old_pwd/run-cjava-compiler.scm $mode $recipe $targets $sources;;
					Racket)
						measure plt-r6rs ++path "$old_pwd/cjava-racr/racket-bin" ++path "$old_pwd/../../racr/racket-bin" \
							$old_pwd/run-cjava-compiler.scm $mode $recipe $targets $sources;;
					Java_d)
						measure java -jar $old_pwd/cjava-jastadd/cjava-declarative.jar \
							$mode $recipe $targets $sources;;
					Java_i)
						measure java -jar $old_pwd/cjava-jastadd/cjava-iterative.jar \
							$mode $recipe $targets $sources;;
					Java_ic)
						measure java -jar $old_pwd/cjava-jastadd/cjava-iterative-cached.jar \
							$mode $recipe $targets $sources;;
					*) # Never encountered!
						echo "++++++++++++++++++++++++++++++++++++ SCRIPT-ERROR ++++++++++++++++++++++++++++++++++++";;
					esac
				fi
			done
		fi
	done
	echo ""
done

my_exit