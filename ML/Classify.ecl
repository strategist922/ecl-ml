﻿IMPORT * FROM $;
/*
		The object of the classify module is to generate a classifier.
    A classifier is an 'equation' or 'algorithm' that allows the 'class' of an object to be imputed based upon other properties
    of an object.
*/

EXPORT Classify := MODULE

SHARED SampleCorrection := 1;
SHARED LogScale(REAL P) := -LOG(P)/LOG(2);

/* Naive Bayes Classification 
	 This method can support producing classification results for multiple classifiers at once
	 Note the presumption that the result (a weight for each value of each field) can fit in memory at once
*/

SHARED BayesResult := RECORD
	  Types.t_discrete c;
		Types.t_discrete f := 0;
		Types.t_FieldNumber number := 0; // Number of the field in question - 0 for the case of a P(C)
		Types.t_FieldNumber class_number;
		REAL8 P; // Either P(F|C) or P(C) if number = 0. Stored in -Log2(P) - so small is good :)
		Types.t_Count Support; // Number of cases
  END;

/*
  The inputs to the BuildNaiveBayes are:
  a) A dataset of discretized independant variables
  b) A dataset of class results (these must match in ID the discretized independant variables).
     Some routines can produce multiple classifiers at once; if so these are distinguished using the NUMBER field of cl
*/
EXPORT BuildNaiveBayes(DATASET(Types.DiscreteField) dd,DATASET(Types.DiscreteField) cl) := FUNCTION
  Triple := RECORD
	  Types.t_Discrete c;
		Types.t_Discrete f;
		Types.t_FieldNumber number;
		Types.t_FieldNumber class_number;
	END;
	Triple form(dd le,cl ri) := TRANSFORM
		SELF.c := ri.value;
		SELF.f := le.value;
		SELF.number := le.number;
		SELF.class_number := ri.number;
	END;
	Vals := JOIN(dd,cl,LEFT.id=RIGHT.id,form(LEFT,RIGHT));
	AggregatedTriple := RECORD
	  Vals.c;
		Vals.f;
		Vals.number;
		Vals.class_number;
		Types.t_Count support := COUNT(GROUP);
	END;
// This is the raw table - how many of each value 'f' for each field 'number' appear for each value 'c' of each classifier 'class_number'
	Cnts := TABLE(Vals,AggregatedTriple,c,f,number,class_number,FEW);

// Compute P(C)
  CTots := TABLE(cl,{value,number,Support := COUNT(GROUP)},value,number,FEW);
  CLTots := TABLE(CTots,{number,TSupport := SUM(GROUP,Support)},number,FEW);
	
	P_C_Rec := RECORD
	  Types.t_Discrete c; // The value within the class
		Types.t_Discrete class_number; // Used when multiple classifiers being produced at once
		Types.t_FieldReal support;  // Used to store total number of C
		REAL8 P; // P(C)
	END;
	P_C_Rec pct(CTots le,CLTots ri) := TRANSFORM
		SELF.c := le.value;
		SELF.class_number := ri.number;
		SELF.support := le.Support;
		SELF.P := le.Support/ri.TSupport;
	END;
	PC := JOIN(CTots,CLTots,LEFT.number=RIGHT.number,pct(LEFT,RIGHT),FEW);
	
	// We do NOT want to assume every value exists for every field - so we will count the number of class values by field
	TotalFs := TABLE(Cnts,{c,number,class_number,Types.t_Count Support := SUM(GROUP,Support),GC := COUNT(GROUP)},c,number,class_number,FEW);
	F_Given_C_Rec := RECORD
	  Cnts.c;
		Cnts.f;
		Cnts.number;
		Cnts.class_number;
		Cnts.support;
		REAL8 P;	
	END;
	F_Given_C_Rec mp(Cnts le,TotalFs ri) := TRANSFORM
	  SELF.P := (le.Support+SampleCorrection) / (ri.Support+ri.GC*SampleCorrection);
		SELF := le;
	END;
	FC := JOIN(Cnts,TotalFs,LEFT.C = RIGHT.C AND LEFT.number=RIGHT.number AND LEFT.class_number=RIGHT.class_number,mp(LEFT,RIGHT),LOOKUP);

	Pret := PROJECT(FC,TRANSFORM(BayesResult,SELF := LEFT))+PROJECT(PC,TRANSFORM(BayesResult,SELF:=LEFT));
	RETURN PROJECT(Pret,TRANSFORM(BayesResult,SELF.P := LogScale(LEFT.P),SELF := LEFT));
END;

// This function will take a pre-existing NaiveBayes model (mo) and score every row of a discretized dataset
// The output will have a row for every row of dd and a column for every class in the original training set
EXPORT NaiveBayes(DATASET(Types.DiscreteField) d,DATASET(BayesResult) mo) := FUNCTION
  // Firstly we can just compute the support for each class from the bayes result
	dd := DISTRIBUTE(d,HASH(id)); // One of those rather nice embarassingly parallel activities
	Inter := RECORD
	  Types.t_discrete c;
		Types.t_discrete class_number;
		Types.t_RecordId Id;
		REAL8  P;
	END;
	Inter note(dd le,mo ri) := TRANSFORM
	  SELF.c := ri.c;
		SELF.class_number := ri.class_number;
		SELF.id := le.id;
		SELF.P := ri.p;
	END;
	// RHS is small so ,ALL join should work ok
	// Ignore the "explicitly distributed" compiler warning - the many lookup is preserving the distribution
	J := JOIN(dd,mo,LEFT.number=RIGHT.number AND LEFT.value=RIGHT.f,note(LEFT,RIGHT),MANY LOOKUP);
	InterCounted := RECORD
	  J.c;
		J.class_number;
		J.id;
		REAL8 P := SUM(GROUP,J.P);
		Types.t_FieldNumber Missing := COUNT(GROUP); // not really missing just yet :)
	END;
	TSum := TABLE(J,InterCounted,c,class_number,id,LOCAL);
	// Now we have the sums for all the F present for each class we need to
	// a) Add in the P(C)
	// b) Suitably penalize any 'f' which simply were not present in the model
	// We start by counting how many not present ...
	FTots := TABLE(DD,{id,c := COUNT(GROUP)},id,LOCAL);
	InterCounted NoteMissing(TSum le,FTots ri) := TRANSFORM
	  SELF.Missing := ri.c - le.Missing;
	  SELF := le;
	END;
	MissingNoted := JOIN(Tsum,FTots,LEFT.id=RIGHT.id,NoteMissing(LEFT,RIGHT),LOOKUP);
	InterCounted NoteC(MissingNoted le,mo ri) := TRANSFORM
	  SELF.P := le.P+ri.P+le.Missing*LogScale(SampleCorrection/ri.support);
	  SELF := le;
	END;
	CNoted := JOIN(MissingNoted,mo(number=0),LEFT.c=RIGHT.c,NoteC(LEFT,RIGHT),LOOKUP);

  RETURN CNoted;
  END;

END;