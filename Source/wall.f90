MODULE WALL_ROUTINES

! Compute the wall boundary conditions

USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS

IMPLICIT NONE
PRIVATE

PUBLIC WALL_BC,TGA_ANALYSIS


CONTAINS


SUBROUTINE WALL_BC(T,DT,NM)

! This is the main control routine for this module

USE COMP_FUNCTIONS, ONLY: SECOND
USE SOOT_ROUTINES, ONLY: CALC_DEPOSITION,SURFACE_OXIDATION
REAL(EB) :: TNOW
REAL(EB), INTENT(IN) :: T,DT
INTEGER, INTENT(IN) :: NM
INTEGER :: IIG,JJG,KKG,IW
TYPE(WALL_TYPE), POINTER :: WC
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB), POINTER :: UWP

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

CALL POINT_TO_MESH(NM)

CALL DIFFUSIVITY_BC
CALL THERMAL_BC(T,DT,NM)
IF (DEPOSITION .AND. .NOT.INITIALIZATION_PHASE) CALL CALC_DEPOSITION(DT,NM)
IF (SOOT_OXIDATION) CALL SURFACE_OXIDATION(DT,NM)
IF (HVAC_SOLVE .AND. .NOT.INITIALIZATION_PHASE) CALL HVAC_BC
CALL SPECIES_BC(T,DT,NM)
CALL DENSITY_BC
IF (N_FACE>0 .AND. .NOT.INITIALIZATION_PHASE)   CALL GEOM_BC
IF (TRANSPORT_UNMIXED_FRACTION)                 CALL ZETA_BC

! After all the boundary conditions have been applied, check the special case where gases are drawn into a solid boundary.
! In this case, set temperature, species, and density to the near gas cell values.

IF (PREDICTOR) THEN
   RHOP => RHOS
   ZZP  => ZZS
ELSE
   RHOP => RHO
   ZZP  => ZZ
ENDIF

WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC=>WALL(IW)

   WC%TMP_F_GAS = WC%ONE_D%TMP_F  ! Unless otherwise indicated, the two wall temperatures are the same.

   IF (WC%BOUNDARY_TYPE/=SOLID_BOUNDARY) CYCLE WALL_LOOP

   IF (PREDICTOR) THEN
      UWP => WC%ONE_D%UWS
   ELSE
      UWP => WC%ONE_D%UW
   ENDIF

   IF (UWP<=0._EB) CYCLE WALL_LOOP  ! The lines below only apply to solid surface that draw gases in.

   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   WC%TMP_F_GAS = TMP(IIG,JJG,KKG)
   WC%ZZ_F(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
   WC%RHO_F = RHOP(IIG,JJG,KKG)
   IF (TRANSPORT_UNMIXED_FRACTION) WC%ZZ_F(ZETA_INDEX) = ZZP(IIG,JJG,KKG,ZETA_INDEX)

ENDDO WALL_LOOP

T_USED(6)=T_USED(6)+SECOND()-TNOW
END SUBROUTINE WALL_BC


SUBROUTINE TGA_ANALYSIS

! This routine performs a numerical TGA (thermo-gravimetric analysis) at the start of the simulation

USE PHYSICAL_FUNCTIONS, ONLY: SURFACE_DENSITY
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
REAL(EB) :: DT_TGA=0.01_EB,T_TGA,SURF_DEN,SURF_DEN_0,HRR
INTEGER :: N_TGA,I,IW,IP
CHARACTER(80) :: MESSAGE,TCFORM
TYPE(ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D

CALL POINT_TO_MESH(1)

RADIATION = .FALSE.
TGA_HEATING_RATE = TGA_HEATING_RATE/60._EB  ! K/min --> K/s
TGA_FINAL_TEMPERATURE = TGA_FINAL_TEMPERATURE + TMPM  ! C --> K
I_RAMP_AGT = 0
N_TGA = NINT((TGA_FINAL_TEMPERATURE-TMPA)/(TGA_HEATING_RATE*DT_TGA))
T_TGA = 0._EB

IF (TGA_WALL_INDEX>0) THEN
   IW = TGA_WALL_INDEX
   ONE_D => WALL(IW)%ONE_D
ELSEIF (TGA_PARTICLE_INDEX>0) THEN
   IP = TGA_PARTICLE_INDEX
   ONE_D => LAGRANGIAN_PARTICLE(IP)%ONE_D
ELSE
   WRITE(MESSAGE,'(A)') 'ERROR: No wall or particle to which to apply the TGA analysis'
   CALL SHUTDOWN(MESSAGE) ; RETURN
ENDIF

OPEN (LU_TGA,FILE=FN_TGA,FORM='FORMATTED',STATUS='REPLACE')
WRITE(LU_TGA,'(A)') 's,C,g/g,1/s,W/g,W/g'
WRITE(LU_TGA,'(A)') 'Time,Temp,Mass,MLR,MCC,DSC'

SURF_DEN_0 = SURFACE(TGA_SURF_INDEX)%SURFACE_DENSITY
WRITE(TCFORM,'(5A)') "(5(",TRIM(FMT_R),",','),",TRIM(FMT_R),")"

DO I=1,N_TGA
   IF (ONE_D%LAYER_THICKNESS(1)<TWO_EPSILON_EB) EXIT
   T_TGA = I*DT_TGA
   ASSUMED_GAS_TEMPERATURE = TMPA + TGA_HEATING_RATE*T_TGA
   IF (TGA_WALL_INDEX>0) THEN
      CALL PYROLYSIS(1,T_TGA,DT_TGA,WALL_INDEX=IW)
      SURF_DEN = SURFACE_DENSITY(1,0,WALL_INDEX=IW)
   ELSE
      CALL PYROLYSIS(1,T_TGA,DT_TGA,PARTICLE_INDEX=IP)
      SURF_DEN = SURFACE_DENSITY(1,0,LAGRANGIAN_PARTICLE_INDEX=IP)
   ENDIF
   IF (MOD(I,NINT(1._EB/(TGA_HEATING_RATE*DT_TGA)))==0) THEN
      IF (N_REACTIONS>0) THEN
         HRR = ONE_D%MASSFLUX(REACTION(1)%FUEL_SMIX_INDEX)*0.001*REACTION(1)%HEAT_OF_COMBUSTION/(ONE_D%AREA_ADJUST*SURF_DEN_0)
      ELSE
         HRR = 0._EB
      ENDIF
      WRITE(LU_TGA,TCFORM) REAL(T_TGA,FB), REAL(ONE_D%TMP_F-TMPM,FB), REAL(SURF_DEN/SURF_DEN_0,FB), &
                           REAL(SUM(ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES))/SURF_DEN_0,FB), &
                           REAL(HRR,FB), REAL(ONE_D%QCONF*0.001_EB/SURF_DEN_0,FB)
   ENDIF
ENDDO

CLOSE(LU_TGA)

END SUBROUTINE TGA_ANALYSIS


SUBROUTINE DIFFUSIVITY_BC

! Calculate the term RHODW=RHO*D at the wall

INTEGER :: IW,N,ITMP,IIG,JJG,KKG
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

IF (N_TRACKED_SPECIES==1) RETURN

IF (PREDICTOR) RHOP => RHOS
IF (CORRECTOR) RHOP => RHO

WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC=>WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
       WC%BOUNDARY_TYPE==OPEN_BOUNDARY .OR. WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE WALL_LOOP
   IF (LES .AND. .NOT. RESEARCH_MODE) THEN
      DO N=1,N_TRACKED_SPECIES
         IIG = WC%ONE_D%IIG
         JJG = WC%ONE_D%JJG
         KKG = WC%ONE_D%KKG
         WC%RHODW(N) = MU(IIG,JJG,KKG)*RSC*WC%RHO_F/RHOP(IIG,JJG,KKG)
      ENDDO
   ELSE
      DO N=1,N_TRACKED_SPECIES
         ITMP = MIN(4999,NINT(WC%ONE_D%TMP_F))
         WC%RHODW(N) = WC%RHO_F*D_Z(ITMP,N)
      ENDDO
   ENDIF
ENDDO WALL_LOOP

END SUBROUTINE DIFFUSIVITY_BC


SUBROUTINE THERMAL_BC(T,DT,NM)

! Thermal boundary conditions for adiabatic, fixed temperature, fixed flux and interpolated boundaries.
! One dimensional heat transfer and pyrolysis is done in PYROLYSIS, which is called at the end of this routine.

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_SPECIFIC_HEAT,GET_VISCOSITY
REAL(EB), INTENT(IN) :: T,DT
REAL(EB) :: DT_BC,DTMP
INTEGER  :: SURF_INDEX,IW,IP
INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL(),OM_RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP=>NULL()
TYPE(LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC=>NULL()

IF (VEG_LEVEL_SET_UNCOUPLED) RETURN

IF (PREDICTOR) THEN
   UU => US
   VV => VS
   WW => WS
   RHOP => RHOS
   ZZP  => ZZS
   PBAR_P => PBAR_S
ELSE
   UU => U
   VV => V
   WW => W
   RHOP => RHO
   ZZP  => ZZ
   PBAR_P => PBAR
ENDIF

! For thermally-thick boundary conditions, set the flag to call the routine PYROLYSIS

CALL_PYROLYSIS = .FALSE.
IF (.NOT.INITIALIZATION_PHASE .AND. CORRECTOR) THEN
   WALL_COUNTER = WALL_COUNTER + 1
   IF (WALL_COUNTER==WALL_INCREMENT) THEN
      DT_BC    = T - BC_CLOCK
      BC_CLOCK = T
      CALL_PYROLYSIS = .TRUE.
      WALL_COUNTER = 0
   ENDIF
ENDIF

! Loop through all boundary cells and apply heat transfer method, except for thermally-thick cells

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC=>WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE WALL_CELL_LOOP

   SURF_INDEX = WC%SURF_INDEX

   CALL HEAT_TRANSFER_BC(WC%ONE_D%TMP_F,WALL_INDEX=IW)

   WC=>WALL(IW)
   IF (SURFACE(SURF_INDEX)%THERMALLY_THICK) THEN
      IF (WC%ONE_D%BURNAWAY) THEN
         WC%ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)=0
      ELSE
         IF (CALL_PYROLYSIS) CALL PYROLYSIS(NM,T,DT_BC,WALL_INDEX=IW)
      ENDIF
   ENDIF

END DO WALL_CELL_LOOP

IF (SOLID_PARTICLES) THEN
   DO IP = 1, NLP
      LP => LAGRANGIAN_PARTICLE(IP)
      LPC => LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)
      IF (LPC%SOLID_PARTICLE) THEN
         SURF_INDEX = LPC%SURF_INDEX
         CALL HEAT_TRANSFER_BC(LP%ONE_D%TMP_F,PARTICLE_INDEX=IP)
         IF (SURFACE(SURF_INDEX)%THERMALLY_THICK .AND. CALL_PYROLYSIS) CALL PYROLYSIS(NM,T,DT_BC,PARTICLE_INDEX=IP)
      ENDIF
   ENDDO
ENDIF

! *********************** UNDER CONSTRUCTION *************************
! Note: With HT3D called after PRYOLYSIS, HT3D inherits the PYRO TMP_F
IF (SOLID_HT3D .AND. CORRECTOR) CALL SOLID_HEAT_TRANSFER_3D(T)
! ********************************************************************


CONTAINS


SUBROUTINE HEAT_TRANSFER_BC(TMP_F,WALL_INDEX,PARTICLE_INDEX)

USE MASS, ONLY: SCALAR_FACE_VALUE

INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX,PARTICLE_INDEX
REAL(EB), INTENT(INOUT) :: TMP_F
REAL(EB) :: AREA_ADJUST,ARO,FDERIV,QEXTRA,QNET,RAMP_FACTOR,RHO_G,RHO_G_2,RSUM_W,TMP_G,TMP_OTHER,TSI,UN, &
            RHO_ZZ_F(1:N_TOTAL_SCALARS),ZZ_GET(1:N_TRACKED_SPECIES),T_IGN,DUMMY, & !ZZ_G_ALL(MAX_SPECIES),
            ZZZ(1:4),RHO_OTHER,RHO_OTHER_2,RHO_ZZ_OTHER(1:N_TOTAL_SCALARS),RHO_ZZ_OTHER_2,RHO_ZZ_G,RHO_ZZ_G_2

LOGICAL :: INFLOW,SECOND_ORDER_INTERPOLATED_BOUNDARY
INTEGER :: II,JJ,KK,IIG,JJG,KKG,IOR,IIO,JJO,KKO,N,ADCOUNT,ICG,ICO
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(EXTERNAL_WALL_TYPE), POINTER :: EWC=>NULL()
TYPE(LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP=>NULL()
TYPE(ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (VENTS_TYPE), POINTER :: VT=>NULL()
TYPE (OMESH_TYPE), POINTER :: OM=>NULL()
TYPE (MESH_TYPE), POINTER :: MM=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: OM_ZZP=>NULL()

SF  => SURFACE(SURF_INDEX)

IF (PRESENT(WALL_INDEX)) THEN
   WC=>WALL(WALL_INDEX)
   ONE_D => WC%ONE_D
   AREA_ADJUST = ONE_D%AREA_ADJUST
   II  = ONE_D%II
   JJ  = ONE_D%JJ
   KK  = ONE_D%KK
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   IOR = ONE_D%IOR
   T_IGN = ONE_D%T_IGN
ELSEIF (PRESENT(PARTICLE_INDEX)) THEN
   LP=>LAGRANGIAN_PARTICLE(PARTICLE_INDEX)
   ONE_D => LP%ONE_D
   AREA_ADJUST = 1._EB
   II  = ONE_D%IIG
   JJ  = ONE_D%JJG
   KK  = ONE_D%KKG
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   IOR = ONE_D%IOR
   T_IGN = ONE_D%T_IGN
ELSE
   RETURN
ENDIF

! Compute surface temperature, TMP_F, and convective heat flux, QCONF, for various boundary conditions

METHOD_OF_HEAT_TRANSFER: SELECT CASE(SF%THERMAL_BC_INDEX)

   CASE (NO_CONVECTION) METHOD_OF_HEAT_TRANSFER

      TMP_F  = TMP(IIG,JJG,KKG)

   CASE (INFLOW_OUTFLOW) METHOD_OF_HEAT_TRANSFER ! Only for wall cells

      ! Base inflow/outflow decision on velocity component with same predictor/corrector attribute

      INFLOW = .FALSE.
      SELECT CASE(IOR)
         CASE( 1)
            UN = UU(II,JJ,KK)
         CASE(-1)
            UN = -UU(II-1,JJ,KK)
         CASE( 2)
            UN = VV(II,JJ,KK)
         CASE(-2)
            UN = -VV(II,JJ-1,KK)
         CASE( 3)
            UN = WW(II,JJ,KK)
         CASE(-3)
            UN = -WW(II,JJ,KK-1)
      END SELECT
      IF (UN>TWO_EPSILON_EB) INFLOW = .TRUE.

      IF (INFLOW) THEN
         TMP_F = TMP_0(KK)
         IF (WC%VENT_INDEX>0) THEN
            VT => VENTS(WC%VENT_INDEX)
            IF (VT%TMP_EXTERIOR>0._EB) &
               TMP_F = TMP_0(KK) + EVALUATE_RAMP(TSI,DUMMY,VT%TMP_EXTERIOR_RAMP_INDEX)*(VT%TMP_EXTERIOR-TMP_0(KK))
         ENDIF
         WC%ZZ_F(1:N_TRACKED_SPECIES)=SPECIES_MIXTURE(1:N_TRACKED_SPECIES)%ZZ0
      ELSE
         TMP_F = TMP(IIG,JJG,KKG)
         WC%ZZ_F(1:N_TRACKED_SPECIES)=ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
      ENDIF

      ! Ghost cell values

      TMP(II,JJ,KK) = TMP_F
      ZZP(II,JJ,KK,1:N_TRACKED_SPECIES) = WC%ZZ_F(1:N_TRACKED_SPECIES)
      ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZP(II,JJ,KK,1:N_TRACKED_SPECIES))
      CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(II,JJ,KK))
      RHOP(II,JJ,KK) = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM(II,JJ,KK)*TMP(II,JJ,KK))

      ONE_D%QCONF = 2._EB*WC%KW*(TMP(IIG,JJG,KKG)-TMP_F)*WC%RDN

   CASE (SPECIFIED_TEMPERATURE) METHOD_OF_HEAT_TRANSFER

      TMP_G = TMP(IIG,JJG,KKG)

      IF (ABS(T_IGN-T_BEGIN) <= SPACING(T_IGN) .AND. SF%RAMP_INDEX(TIME_TEMP)>=1) THEN
         TSI = T
      ELSE
         TSI = T - T_IGN
      ENDIF

      IF (PRESENT(PARTICLE_INDEX) .AND. IBM_FEM_COUPLING) THEN
         TMP_F = FACET(LP%FACE_INDEX)%TMP_F
      ELSE
         IF (ONE_D%UW<=0._EB) THEN
            IF (SF%TMP_FRONT>0._EB) THEN
               TMP_F = TMP_0(KK) + EVALUATE_RAMP(TSI,SF%TAU(TIME_TEMP),SF%RAMP_INDEX(TIME_TEMP))*(SF%TMP_FRONT-TMP_0(KK))
            ELSE
               TMP_F = TMP_0(KK)
            ENDIF
         ELSE
            TMP_F = TMP_G ! If gas is being drawn from the domain, set the boundary temperature to the gas temperature
         ENDIF
      ENDIF

      DTMP = TMP_G - TMP_F
      IF (PRESENT(WALL_INDEX)) THEN
         ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                           SF%ROUGHNESS,WC%SURF_INDEX,WALL_INDEX=WALL_INDEX)
      ELSE
         ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                           SF%ROUGHNESS,LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)%SURF_INDEX,&
                                                           PARTICLE_INDEX=PARTICLE_INDEX)
      ENDIF
      ONE_D%QCONF = ONE_D%HEAT_TRANS_COEF*DTMP

   CASE (NET_FLUX_BC) METHOD_OF_HEAT_TRANSFER

      IF (ABS(T_IGN-T_BEGIN)<= SPACING(T_IGN) .AND. SF%RAMP_INDEX(TIME_HEAT)>=1) THEN
         TSI = T
      ELSE
         TSI = T - T_IGN
      ENDIF
      TMP_G = TMP(IIG,JJG,KKG)
      TMP_OTHER = TMP_F
      RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%TAU(TIME_HEAT),SF%RAMP_INDEX(TIME_HEAT))
      QNET = -RAMP_FACTOR*SF%NET_HEAT_FLUX*AREA_ADJUST
      ADCOUNT = 0
      ADLOOP: DO
         ADCOUNT = ADCOUNT + 1
         DTMP = TMP_G - TMP_OTHER
         IF (ABS(QNET) > 0._EB .AND. ABS(DTMP) <TWO_EPSILON_EB) DTMP=1._EB
         IF (PRESENT(WALL_INDEX)) THEN
            ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                              SF%ROUGHNESS,WC%SURF_INDEX,WALL_INDEX=WALL_INDEX)
         ELSE
            ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                              SF%ROUGHNESS,LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)%SURF_INDEX,&
                                                              PARTICLE_INDEX=PARTICLE_INDEX)
         ENDIF
         IF (RADIATION) THEN
            QEXTRA = ONE_D%HEAT_TRANS_COEF*DTMP + ONE_D%QRADIN - ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 4 - QNET
            FDERIV = -ONE_D%HEAT_TRANS_COEF -  4._EB * ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 3
         ELSE
            QEXTRA = ONE_D%HEAT_TRANS_COEF*DTMP - QNET
            FDERIV = -ONE_D%HEAT_TRANS_COEF
         ENDIF
         IF (ABS(FDERIV) > TWO_EPSILON_EB) TMP_OTHER = TMP_OTHER - QEXTRA / FDERIV
         IF (ABS(TMP_OTHER - TMP_F) / TMP_F < 1.E-4_EB .OR. ADCOUNT > 20) THEN
            TMP_F = MIN(TMPMAX,TMP_OTHER)
            EXIT ADLOOP
         ELSE
            TMP_F = MIN(TMPMAX,TMP_OTHER)
            CYCLE ADLOOP
         ENDIF
      ENDDO ADLOOP

      ONE_D%QCONF = ONE_D%HEAT_TRANS_COEF*DTMP

   CASE (CONVECTIVE_FLUX_BC) METHOD_OF_HEAT_TRANSFER

      IF (ABS(T_IGN-T_BEGIN) <= SPACING(T_IGN) .AND. SF%RAMP_INDEX(TIME_HEAT)>=1) THEN
         TSI = T
      ELSE
         TSI = T - T_IGN
      ENDIF
      RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%TAU(TIME_HEAT),SF%RAMP_INDEX(TIME_HEAT))
      IF (SF%TMP_FRONT>0._EB) THEN
         TMP_F =  TMPA + RAMP_FACTOR*(SF%TMP_FRONT-TMPA)
      ELSE
         TMP_F =  TMP_0(KK)
      ENDIF
      ONE_D%QCONF = -RAMP_FACTOR*SF%CONVECTIVE_HEAT_FLUX*AREA_ADJUST

   CASE (INTERPOLATED_BC) METHOD_OF_HEAT_TRANSFER

      EWC => EXTERNAL_WALL(WALL_INDEX)
      OM => OMESH(EWC%NOM)
      IF (PREDICTOR) THEN
         OM_RHOP => OM%RHOS
         OM_ZZP => OM%ZZS
      ELSE
         OM_RHOP => OM%RHO
         OM_ZZP => OM%ZZ
      ENDIF
      MM => MESHES(EWC%NOM)

      ! Gather data from other mesh

      RHO_OTHER=0._EB
      RHO_ZZ_OTHER=0._EB

      DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
         DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
            DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
               SELECT CASE(IOR)
                  CASE( 1)
                     ARO = MIN(1._EB , (MM%DY(JJO)*MM%DZ(KKO))/(DY(JJ)*DZ(KK)) )
                  CASE(-1)
                     ARO = MIN(1._EB , (MM%DY(JJO)*MM%DZ(KKO))/(DY(JJ)*DZ(KK)) )
                  CASE( 2)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DZ(KKO))/(DX(II)*DZ(KK)) )
                  CASE(-2)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DZ(KKO))/(DX(II)*DZ(KK)) )
                  CASE( 3)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DY(JJO))/(DX(II)*DY(JJ)) )
                  CASE(-3)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DY(JJO))/(DX(II)*DY(JJ)) )
               END SELECT
               RHO_OTHER = RHO_OTHER + ARO*OM_RHOP(IIO,JJO,KKO)
               RHO_ZZ_OTHER(1:N_TOTAL_SCALARS) = RHO_ZZ_OTHER(1:N_TOTAL_SCALARS) &
                  + ARO*OM_RHOP(IIO,JJO,KKO)*OM_ZZP(IIO,JJO,KKO,1:N_TOTAL_SCALARS)
            ENDDO
         ENDDO
      ENDDO

      ! Determine if there are 4 equally sized cells spanning the interpolated boundary

      SECOND_ORDER_INTERPOLATED_BOUNDARY = .FALSE.
      IF (ABS(EWC%AREA_RATIO-1._EB)<0.01_EB) THEN
         IIO = EWC%IIO_MIN
         JJO = EWC%JJO_MIN
         KKO = EWC%KKO_MIN
         SELECT CASE(IOR)
            CASE( 1) ; ICG = CELL_INDEX(IIG+1,JJG,KKG) ; ICO = MM%CELL_INDEX(IIO-1,JJO,KKO)
            CASE(-1) ; ICG = CELL_INDEX(IIG-1,JJG,KKG) ; ICO = MM%CELL_INDEX(IIO+1,JJO,KKO)
            CASE( 2) ; ICG = CELL_INDEX(IIG,JJG+1,KKG) ; ICO = MM%CELL_INDEX(IIO,JJO-1,KKO)
            CASE(-2) ; ICG = CELL_INDEX(IIG,JJG-1,KKG) ; ICO = MM%CELL_INDEX(IIO,JJO+1,KKO)
            CASE( 3) ; ICG = CELL_INDEX(IIG,JJG,KKG+1) ; ICO = MM%CELL_INDEX(IIO,JJO,KKO-1)
            CASE(-3) ; ICG = CELL_INDEX(IIG,JJG,KKG-1) ; ICO = MM%CELL_INDEX(IIO,JJO,KKO+1)
         END SELECT
         IF (.NOT.SOLID(ICG) .AND. .NOT.MM%SOLID(ICO)) SECOND_ORDER_INTERPOLATED_BOUNDARY = .TRUE.
      ENDIF

      ! Density

      RHO_G = RHOP(IIG,JJG,KKG)
      RHO_G_2 = RHO_G ! first-order (default)
      RHOP(II,JJ,KK) = RHO_OTHER
      RHO_OTHER_2 = RHO_OTHER

      SELECT CASE(IOR)
         CASE( 1)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG+1,JJG,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO-1,JJO,KKO)
            ENDIF
            ZZZ(1:4) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(UU(II,JJ,KK),ZZZ,FLUX_LIMITER)
         CASE(-1)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG-1,JJG,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO+1,JJO,KKO)
            ENDIF
            ZZZ(1:4) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(UU(II-1,JJ,KK),ZZZ,FLUX_LIMITER)
         CASE( 2)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG+1,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO-1,KKO)
            ENDIF
            ZZZ(1:4) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(VV(II,JJ,KK),ZZZ,FLUX_LIMITER)
         CASE(-2)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG-1,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO+1,KKO)
            ENDIF
            ZZZ(1:4) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(VV(II,JJ-1,KK),ZZZ,FLUX_LIMITER)
         CASE( 3)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG,KKG+1)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO,KKO-1)
            ENDIF
            ZZZ(1:4) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(WW(II,JJ,KK),ZZZ,FLUX_LIMITER)
         CASE(-3)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG,KKG-1)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO,KKO+1)
            ENDIF
            ZZZ(1:4) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            WC%RHO_F = SCALAR_FACE_VALUE(WW(II,JJ,KK-1),ZZZ,FLUX_LIMITER)
      END SELECT

      ! Species

      SINGLE_SPEC_IF: IF (N_TOTAL_SCALARS > 1) THEN
         SPECIES_LOOP: DO N=1,N_TOTAL_SCALARS

            RHO_ZZ_G = RHO_G*ZZP(IIG,JJG,KKG,N)
            RHO_ZZ_G_2 = RHO_ZZ_G ! first-order (default)
            RHO_ZZ_OTHER_2 = RHO_ZZ_OTHER(N)

            SELECT CASE(IOR)
               CASE( 1)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG+1,JJG,KKG)*ZZP(IIG+1,JJG,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO-1,JJO,KKO)*OM_ZZP(IIO-1,JJO,KKO,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(UU(II,JJ,KK),ZZZ,FLUX_LIMITER)
               CASE(-1)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG-1,JJG,KKG)*ZZP(IIG-1,JJG,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO+1,JJO,KKO)*OM_ZZP(IIO+1,JJO,KKO,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(UU(II-1,JJ,KK),ZZZ,FLUX_LIMITER)
               CASE( 2)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG+1,KKG)*ZZP(IIG,JJG+1,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO-1,KKO)*OM_ZZP(IIO,JJO-1,KKO,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(VV(II,JJ,KK),ZZZ,FLUX_LIMITER)
               CASE(-2)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG-1,KKG)*ZZP(IIG,JJG-1,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO+1,KKO)*OM_ZZP(IIO,JJO+1,KKO,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(VV(II,JJ-1,KK),ZZZ,FLUX_LIMITER)
               CASE( 3)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG,KKG+1)*ZZP(IIG,JJG,KKG+1,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO,KKO-1)*OM_ZZP(IIO,JJO,KKO-1,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(WW(II,JJ,KK),ZZZ,FLUX_LIMITER)
               CASE(-3)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG,KKG-1)*ZZP(IIG,JJG,KKG-1,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO,KKO+1)*OM_ZZP(IIO,JJO,KKO+1,N)
                  ENDIF
                  ZZZ(1:4) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  RHO_ZZ_F(N) = SCALAR_FACE_VALUE(WW(II,JJ,KK-1),ZZZ,FLUX_LIMITER)
            END SELECT
         ENDDO SPECIES_LOOP

         ! face value of temperature
         WC%ZZ_F(1:N_TOTAL_SCALARS) = MAX(0._EB,MIN(1._EB,RHO_ZZ_F(1:N_TOTAL_SCALARS)/WC%RHO_F))
         ZZ_GET(1:N_TRACKED_SPECIES) = WC%ZZ_F(1:N_TRACKED_SPECIES)
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_W)
         TMP_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM_W*WC%RHO_F)
      ELSE SINGLE_SPEC_IF
         WC%ZZ_F(1) = 1._EB
         TMP_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM0*WC%RHO_F)
      ENDIF SINGLE_SPEC_IF

      ! ghost cell value of temperature
      ZZP(II,JJ,KK,1:N_TOTAL_SCALARS) = RHO_ZZ_OTHER(1:N_TOTAL_SCALARS)/RHO_OTHER
      ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZP(II,JJ,KK,1:N_TRACKED_SPECIES))
      CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(II,JJ,KK))
      TMP(II,JJ,KK) = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM(II,JJ,KK)*RHOP(II,JJ,KK))

      ONE_D%QCONF = 0._EB ! no convective heat transfer at interoplated boundary

END SELECT METHOD_OF_HEAT_TRANSFER

END SUBROUTINE HEAT_TRANSFER_BC


SUBROUTINE SOLID_HEAT_TRANSFER_3D(T)

! Solves the 3D heat conduction equation internal to OBSTs.
! Currently, this is not hooked into PYROLYSIS shell elements,
! but this is under development.

REAL(EB), INTENT(IN) :: T
REAL(EB) :: DT_SUB,T_LOC,RHO_S,K_S,C_S,TMP_G,TMP_F,TMP_S,RDN,HTC,K_S_M,K_S_P,H_S,T_IGN,AREA_ADJUST,TMP_OTHER,RAMP_FACTOR,&
            QNET,TSI,FDERIV,QEXTRA,K_S_MAX,VN_HT3D,DN,KDTDN
INTEGER  :: II,JJ,KK,I,J,K,IOR,IC,ICM,ICP,IIG,JJG,KKG,NR,ADCOUNT,SUBIT
REAL(EB), POINTER, DIMENSION(:,:,:) :: KDTDX=>NULL(),KDTDY=>NULL(),KDTDZ=>NULL(),TMP_NEW=>NULL()
TYPE(OBSTRUCTION_TYPE), POINTER :: OB=>NULL(),OBM=>NULL(),OBP=>NULL()
TYPE (MATERIAL_TYPE), POINTER :: ML=>NULL(),MLM=>NULL(),MLP=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()

! Initialize verification tests

IF (ICYC==1) THEN
   SELECT CASE(HT3D_TEST)
      CASE(1); CALL CRANK_TEST_1(1)
      CASE(2); CALL CRANK_TEST_1(2)
      CASE(3); CALL CRANK_TEST_1(3)
   END SELECT
ENDIF

KDTDX=>WORK1; KDTDX=0._EB
KDTDY=>WORK2; KDTDY=0._EB
KDTDZ=>WORK3; KDTDZ=0._EB
TMP_NEW=>WORK4; TMP_NEW=TMP

DT_SUB = DT
T_LOC = 0._EB
SUBIT = 0

SUBSTEP_LOOP: DO WHILE ( ABS(T_LOC-DT)>TWO_EPSILON_EB )
   DT_SUB = MIN(DT_SUB,DT-T_LOC)
   K_S_MAX = 0._EB
   VN_HT3D = 0._EB

   ! build heat flux vectors
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            ICM = CELL_INDEX(I,J,K)
            ICP = CELL_INDEX(I+1,J,K)
            IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
            OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
            OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
            IF (.NOT.(OBM%HT3D.AND.OBP%HT3D)) CYCLE
            MLM => MATERIAL(OBM%MATL_INDEX)
            MLP => MATERIAL(OBP%MATL_INDEX)
            IF (MLM%K_S>0._EB) THEN
               K_S_M = MLM%K_S
            ELSE
               NR = -NINT(MLM%K_S)
               K_S_M = EVALUATE_RAMP(TMP(I,J,K),0._EB,NR)
            ENDIF
            IF (MLP%K_S>0._EB) THEN
               K_S_P = MLP%K_S
            ELSE
               NR = -NINT(MLP%K_S)
               K_S_P = EVALUATE_RAMP(TMP(I+1,J,K),0._EB,NR)
            ENDIF
            K_S = 0.5_EB*(K_S_M+K_S_P)
            K_S_MAX = MAX(K_S_MAX,K_S)
            KDTDX(I,J,K) = K_S * (TMP(I+1,J,K)-TMP(I,J,K))*RDXN(I)
         ENDDO
      ENDDO
   ENDDO
   TWO_D_IF: IF (.NOT.TWO_D) THEN
      DO K=1,KBAR
         DO J=0,JBAR
            DO I=1,IBAR
               ICM = CELL_INDEX(I,J,K)
               ICP = CELL_INDEX(I,J+1,K)
               IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
               OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
               OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
               IF (.NOT.(OBM%HT3D.AND.OBP%HT3D)) CYCLE
               MLM => MATERIAL(OBM%MATL_INDEX)
               MLP => MATERIAL(OBP%MATL_INDEX)
               IF (MLM%K_S>0._EB) THEN
                  K_S_M = MLM%K_S
               ELSE
                  NR = -NINT(MLM%K_S)
                  K_S_M = EVALUATE_RAMP(TMP(I,J,K),0._EB,NR)
               ENDIF
               IF (MLP%K_S>0._EB) THEN
                  K_S_P = MLP%K_S
               ELSE
                  NR = -NINT(MLP%K_S)
                  K_S_P = EVALUATE_RAMP(TMP(I,J+1,K),0._EB,NR)
               ENDIF
               K_S = 0.5_EB*(K_S_M+K_S_P)
               K_S_MAX = MAX(K_S_MAX,K_S)
               KDTDY(I,J,K) = K_S * (TMP(I,J+1,K)-TMP(I,J,K))*RDYN(J)
            ENDDO
         ENDDO
      ENDDO
   ELSE TWO_D_IF
      KDTDY(I,J,K) = 0._EB
   ENDIF TWO_D_IF
   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            ICM = CELL_INDEX(I,J,K)
            ICP = CELL_INDEX(I,J,K+1)
            IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
            OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
            OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
            IF (.NOT.(OBM%HT3D.AND.OBP%HT3D)) CYCLE
            MLM => MATERIAL(OBM%MATL_INDEX)
            MLP => MATERIAL(OBP%MATL_INDEX)
            IF (MLM%K_S>0._EB) THEN
               K_S_M = MLM%K_S
            ELSE
               NR = -NINT(MLM%K_S)
               K_S_M = EVALUATE_RAMP(TMP(I,J,K),0._EB,NR)
            ENDIF
            IF (MLP%K_S>0._EB) THEN
               K_S_P = MLP%K_S
            ELSE
               NR = -NINT(MLP%K_S)
               K_S_P = EVALUATE_RAMP(TMP(I,J,K+1),0._EB,NR)
            ENDIF
            K_S = 0.5_EB*(K_S_M+K_S_P)
            K_S_MAX = MAX(K_S_MAX,K_S)
            KDTDZ(I,J,K) = K_S * (TMP(I,J,K+1)-TMP(I,J,K))*RDZN(K)
         ENDDO
      ENDDO
   ENDDO

   ! build fluxes on boundaries (later hook into pyrolysis code)
   HT3D_WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC => WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE HT3D_WALL_LOOP

      SURF_INDEX = WC%SURF_INDEX
      SF => SURFACE(SURF_INDEX)
      II = WC%ONE_D%II
      JJ = WC%ONE_D%JJ
      KK = WC%ONE_D%KK
      IIG = WC%ONE_D%IIG
      JJG = WC%ONE_D%JJG
      KKG = WC%ONE_D%KKG
      IOR = WC%ONE_D%IOR

      IC = CELL_INDEX(II,JJ,KK);           IF (.NOT.SOLID(IC)) CYCLE HT3D_WALL_LOOP
      OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%HT3D  ) CYCLE HT3D_WALL_LOOP
      ML => MATERIAL(OB%MATL_INDEX)

      IF (ML%K_S>0._EB) THEN
         K_S = ML%K_S
      ELSE
         NR = -NINT(ML%K_S)
         K_S = EVALUATE_RAMP(WC%ONE_D%TMP_F,0._EB,NR)
      ENDIF
      K_S_MAX = MAX(K_S_MAX,K_S)

      METHOD_OF_HEAT_TRANSFER: SELECT CASE(SF%THERMAL_BC_INDEX)

         CASE DEFAULT METHOD_OF_HEAT_TRANSFER ! includes SF%THERMAL_BC_INDEX==SPECIFIED_TEMPERATURE

            SELECT CASE(IOR)
               CASE( 1); KDTDX(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDX(II)
               CASE(-1); KDTDX(II-1,JJ,KK) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDX(II)
               CASE( 2); KDTDY(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDY(JJ)
               CASE(-2); KDTDY(II,JJ-1,KK) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDY(JJ)
               CASE( 3); KDTDZ(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDZ(KK)
               CASE(-3); KDTDZ(II,JJ,KK-1) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDZ(KK)
            END SELECT

         CASE (NET_FLUX_BC) METHOD_OF_HEAT_TRANSFER ! copied from HEAT_TRANSFER_BC

            AREA_ADJUST = WC%ONE_D%AREA_ADJUST
            SELECT CASE(IOR)
               CASE( 1); KDTDX(II,JJ,KK)   = -SF%NET_HEAT_FLUX*AREA_ADJUST
               CASE(-1); KDTDX(II-1,JJ,KK) =  SF%NET_HEAT_FLUX*AREA_ADJUST
               CASE( 2); KDTDY(II,JJ,KK)   = -SF%NET_HEAT_FLUX*AREA_ADJUST
               CASE(-2); KDTDY(II,JJ-1,KK) =  SF%NET_HEAT_FLUX*AREA_ADJUST
               CASE( 3); KDTDZ(II,JJ,KK)   = -SF%NET_HEAT_FLUX*AREA_ADJUST
               CASE(-3); KDTDZ(II,JJ,KK-1) =  SF%NET_HEAT_FLUX*AREA_ADJUST
            END SELECT

            SOLID_PHASE_ONLY_IF: IF (SOLID_PHASE_ONLY) THEN
               SELECT CASE(IOR)
                  CASE( 1); WC%ONE_D%TMP_F = TMP(II,JJ,KK) + KDTDX(II,JJ,KK)   / (K_S * 2._EB * RDX(II))
                  CASE(-1); WC%ONE_D%TMP_F = TMP(II,JJ,KK) - KDTDX(II-1,JJ,KK) / (K_S * 2._EB * RDX(II))
                  CASE( 2); WC%ONE_D%TMP_F = TMP(II,JJ,KK) + KDTDY(II,JJ,KK)   / (K_S * 2._EB * RDY(JJ))
                  CASE(-2); WC%ONE_D%TMP_F = TMP(II,JJ,KK) - KDTDY(II,JJ-1,KK) / (K_S * 2._EB * RDY(JJ))
                  CASE( 3); WC%ONE_D%TMP_F = TMP(II,JJ,KK) + KDTDZ(II,JJ,KK)   / (K_S * 2._EB * RDZ(KK))
                  CASE(-3); WC%ONE_D%TMP_F = TMP(II,JJ,KK) - KDTDZ(II,JJ,KK-1) / (K_S * 2._EB * RDZ(KK))
               END SELECT
            ELSE
               TMP_G = TMP(IIG,JJG,KKG)
               TMP_F = WC%ONE_D%TMP_F
               TMP_OTHER = TMP_F
               DTMP = TMP_G - TMP_F
               T_IGN = WC%ONE_D%T_IGN
               IF (ABS(T_IGN-T_BEGIN)<= SPACING(T_IGN) .AND. SF%RAMP_INDEX(TIME_HEAT)>=1) THEN
                  TSI = T
               ELSE
                  TSI = T - T_IGN
               ENDIF
               RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%TAU(TIME_HEAT),SF%RAMP_INDEX(TIME_HEAT))
               QNET = -RAMP_FACTOR*SF%NET_HEAT_FLUX*AREA_ADJUST
               ADCOUNT = 0
               ADLOOP: DO
                  ADCOUNT = ADCOUNT + 1
                  DTMP = TMP_G - TMP_OTHER
                  IF (ABS(QNET) > 0._EB .AND. ABS(DTMP) <TWO_EPSILON_EB) DTMP=1._EB
                  WC%ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,&
                                             SF%HEAT_TRANSFER_MODEL,SF%ROUGHNESS,WC%SURF_INDEX,WALL_INDEX=IW)
                  HTC = WC%ONE_D%HEAT_TRANS_COEF
                  IF (RADIATION) THEN
                     QEXTRA = WC%ONE_D%HEAT_TRANS_COEF*DTMP + WC%ONE_D%QRADIN - WC%ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 4 - QNET
                     FDERIV = -WC%ONE_D%HEAT_TRANS_COEF -  4._EB * WC%ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 3
                  ELSE
                     QEXTRA = WC%ONE_D%HEAT_TRANS_COEF*DTMP - QNET
                     FDERIV = -WC%ONE_D%HEAT_TRANS_COEF
                  ENDIF
                  IF (ABS(FDERIV) > TWO_EPSILON_EB) TMP_OTHER = TMP_OTHER - QEXTRA / FDERIV
                  IF (ABS(TMP_OTHER - TMP_F) / TMP_F < 1.E-4_EB .OR. ADCOUNT > 20) THEN
                     TMP_F = MIN(TMPMAX,TMP_OTHER)
                     EXIT ADLOOP
                  ELSE
                     TMP_F = MIN(TMPMAX,TMP_OTHER)
                     CYCLE ADLOOP
                  ENDIF
               ENDDO ADLOOP
               WC%ONE_D%TMP_F = TMP_F
               WC%ONE_D%QCONF = HTC*DTMP
            ENDIF SOLID_PHASE_ONLY_IF

         CASE (THERMALLY_THICK) ! TMP_F and HEAT FLUX taken from PYROLYSIS

            TMP_F = WC%ONE_D%TMP_F
            TMP_S = WC%ONE_D%TMP(1)
            DN    = ABS( 0.5_EB*(WC%ONE_D%X(0)-WC%ONE_D%X(1)) ) ! ABS required because X is a "depth"
            HTC   = K_S / DN
            KDTDN = HTC * (TMP_F-TMP_S)

            SELECT CASE(IOR)
               CASE( 1); KDTDX(II,JJ,KK)   =  KDTDN
               CASE(-1); KDTDX(II-1,JJ,KK) = -KDTDN
               CASE( 2); KDTDY(II,JJ,KK)   =  KDTDN
               CASE(-2); KDTDY(II,JJ-1,KK) = -KDTDN
               CASE( 3); KDTDZ(II,JJ,KK)   =  KDTDN
               CASE(-3); KDTDZ(II,JJ,KK-1) = -KDTDN
            END SELECT

            ! check time step

            IF (ML%C_S>0._EB) THEN
               C_S = ML%C_S
            ELSE
               NR = -NINT(ML%C_S)
               C_S = EVALUATE_RAMP(TMP_F,0._EB,NR)
            ENDIF
            RHO_S = ML%RHO_S
            VN_HT3D = MAX( VN_HT3D, HTC/(RHO_S*C_S*DN) )

         CASE (THERMALLY_THICK_HT3D) ! thermally thick, continuous heat flux, not connected with PYROLYSIS

            IIG = WC%ONE_D%IIG
            JJG = WC%ONE_D%JJG
            KKG = WC%ONE_D%KKG
            TMP_G = TMP(IIG,JJG,KKG)
            TMP_S = TMP(II,JJ,KK)
            TMP_F = WC%ONE_D%TMP_F
            DTMP = TMP_G - TMP_F
            WC%ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,&
                                       SF%HEAT_TRANSFER_MODEL,SF%ROUGHNESS,WC%SURF_INDEX,WALL_INDEX=IW)
            HTC = WC%ONE_D%HEAT_TRANS_COEF

            SELECT CASE(ABS(IOR))
               CASE( 1); RDN = RDX(II)
               CASE( 2); RDN = RDY(JJ)
               CASE( 3); RDN = RDZ(KK)
            END SELECT
            IF (RADIATION) THEN
               TMP_F = ( WC%ONE_D%QRADIN +                    HTC*TMP_G + 2._EB*K_S*RDN*TMP_S ) / &
                       ( WC%ONE_D%EMISSIVITY*SIGMA*TMP_F**3 + HTC       + 2._EB*K_S*RDN       )
            ELSE
               TMP_F = ( HTC*TMP_G + 2._EB*K_S*RDN*TMP_S ) / &
                       ( HTC       + 2._EB*K_S*RDN       )
            ENDIF
            WC%ONE_D%TMP_F = TMP_F
            WC%ONE_D%QCONF = HTC*(TMP_G-TMP_F)

            SELECT CASE(IOR)
               CASE( 1); KDTDX(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDX(II)
               CASE(-1); KDTDX(II-1,JJ,KK) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDX(II)
               CASE( 2); KDTDY(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDY(JJ)
               CASE(-2); KDTDY(II,JJ-1,KK) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDY(JJ)
               CASE( 3); KDTDZ(II,JJ,KK)   = K_S * 2._EB*(WC%ONE_D%TMP_F-TMP(II,JJ,KK))*RDZ(KK)
               CASE(-3); KDTDZ(II,JJ,KK-1) = K_S * 2._EB*(TMP(II,JJ,KK)-WC%ONE_D%TMP_F)*RDZ(KK)
            END SELECT

      END SELECT METHOD_OF_HEAT_TRANSFER

   ENDDO HT3D_WALL_LOOP

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IC = CELL_INDEX(I,J,K)
            IF (.NOT.SOLID(IC)) CYCLE
            OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%HT3D) CYCLE
            ML => MATERIAL(OB%MATL_INDEX)
            RHO_S = ML%RHO_S
            IF (ML%C_S>0._EB) THEN
               C_S = ML%C_S
            ELSE
               NR = -NINT(ML%C_S)
               C_S = EVALUATE_RAMP(TMP(I,J,K),0._EB,NR)
            ENDIF

            VN_HT3D = MAX(VN_HT3D, 2._EB*K_S_MAX/(RHO_S*C_S)*(RDX(I)**2 + RDY(J)**2 + RDZ(K)**2) )

            TMP_NEW(I,J,K) = TMP(I,J,K) + DT_SUB/(RHO_S*C_S) * ( (KDTDX(I,J,K)-KDTDX(I-1,J,K))*RDX(I) + &
                                                                 (KDTDY(I,J,K)-KDTDY(I,J-1,K))*RDY(J) + &
                                                                 (KDTDZ(I,J,K)-KDTDZ(I,J,K-1))*RDZ(K) )
         ENDDO
      ENDDO
   ENDDO

   ! time step adjustment

   IF (DT_SUB*VN_HT3D <= 1._EB .OR. LOCK_TIME_STEP) THEN
      TMP = TMP_NEW
      T_LOC = T_LOC + DT_SUB
      SUBIT = SUBIT + 1
   ENDIF
   IF (VN_HT3D > TWO_EPSILON_EB .AND. .NOT.LOCK_TIME_STEP) DT_SUB = 0.5_EB / VN_HT3D

ENDDO SUBSTEP_LOOP

END SUBROUTINE SOLID_HEAT_TRANSFER_3D


SUBROUTINE CRANK_TEST_1(DIM)
! Initialize solid temperature profile for simple 1D verification test
! J. Crank, The Mathematics of Diffusion, 2nd Ed., Oxford Press, 1975, Sec 2.3.
INTEGER, INTENT(IN) :: DIM ! DIM=1,2,3 for x,y,z dimensions
INTEGER :: I,J,K,IC
REAL(EB), PARAMETER :: LL=1._EB, AA=100._EB, NN=2._EB, X_0=-.5_EB

DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IC = CELL_INDEX(I,J,K)
         IF (.NOT.SOLID(IC)) CYCLE
         SELECT CASE(DIM)
            CASE(1)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(XC(I)-X_0)/LL) ! TMPA = 293.15 K
            CASE(2)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(YC(J)-X_0)/LL)
            CASE(3)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(ZC(K)-X_0)/LL)
         END SELECT
      ENDDO
   ENDDO
ENDDO

END SUBROUTINE CRANK_TEST_1


END SUBROUTINE THERMAL_BC


SUBROUTINE SPECIES_BC(T,DT,NM)

! Compute the species mass fractions at the boundary, ZZ_F

USE PHYSICAL_FUNCTIONS, ONLY: GET_AVERAGE_SPECIFIC_HEAT,GET_SPECIFIC_HEAT,GET_SENSIBLE_ENTHALPY,SURFACE_DENSITY, &
                              GET_SPECIFIC_GAS_CONSTANT
USE TRAN, ONLY: GET_IJK
USE OUTPUT_DATA, ONLY: M_DOT
REAL(EB) :: RADIUS,AREA_SCALING,RVC,M_DOT_PPP_SINGLE,CP,CPBAR,MW_RATIO,H_G,DELTA_H_G,ZZ_GET(1:N_TRACKED_SPECIES),CPBAR2,DENOM
REAL(EB), INTENT(IN) :: T,DT
INTEGER, INTENT(IN) :: NM
INTEGER :: II,JJ,KK,IIG,JJG,KKG,IW,NS,IP,I_FUEL,SPECIES_BC_INDEX
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC=>NULL()
TYPE (LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE (WALL_TYPE), POINTER :: WC=>NULL()
TYPE (ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D=>NULL()

IF (VEG_LEVEL_SET) RETURN

IF (PREDICTOR) THEN
   PBAR_P => PBAR_S
   RHOP => RHOS
   ZZP => ZZS
ELSE
   PBAR_P => PBAR
   RHOP => RHO
   ZZP => ZZ
ENDIF

! Add evaporating gases from solid particles to the mesh using a volumetric source term

PARTICLE_LOOP: DO IP=1,NLP

   LP  => LAGRANGIAN_PARTICLE(IP)
   LPC => LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)

   IF (.NOT.LPC%SOLID_PARTICLE) CYCLE PARTICLE_LOOP

   SF => SURFACE(LPC%SURF_INDEX)
   ONE_D => LP%ONE_D
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   II  = IIG
   JJ  = JJG
   KK  = KKG

   CALL CALC_SPECIES_BC(PARTICLE_INDEX=IP)

   ! Only do basic boundary conditions during the PREDICTOR stage of time step.

   IF (PREDICTOR) CYCLE PARTICLE_LOOP

   ! Get particle radius and surface area

   IF (SF%PYROLYSIS_MODEL==PYROLYSIS_MATERIAL) THEN
      RADIUS = SF%INNER_RADIUS + SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))
   ELSE
      RADIUS = SF%INNER_RADIUS + SF%THICKNESS
   ENDIF

   IF (ABS(RADIUS)<TWO_EPSILON_EB) CYCLE PARTICLE_LOOP

   AREA_SCALING = 1._EB
   IF (LPC%DRAG_LAW /= SCREEN_DRAG .AND. LPC%DRAG_LAW /= POROUS_DRAG) THEN
      SELECT CASE(SF%GEOMETRY)
         CASE(SURF_CARTESIAN)
            ONE_D%AREA = 2._EB*SF%LENGTH*SF%WIDTH
         CASE(SURF_CYLINDRICAL)
            ONE_D%AREA  = TWOPI*RADIUS*SF%LENGTH
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = (SF%INNER_RADIUS+SF%THICKNESS)/RADIUS
         CASE(SURF_SPHERICAL)
            ONE_D%AREA  = 4._EB*PI*RADIUS**2
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = ((SF%INNER_RADIUS+SF%THICKNESS)/RADIUS)**2
      END SELECT
   ENDIF

   ! In PYROLYSIS, all the mass fluxes are normalized by a virtual area based on the INITIAL radius.
   ! Here, correct the mass flux using the CURRENT radius.

   IF (CALL_PYROLYSIS) THEN
      ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)         = ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)       *AREA_SCALING
      ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES)  = ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES)*AREA_SCALING
   ENDIF

   ! Add evaporated particle species to gas phase and compute resulting contribution to the divergence

   RVC = RDX(IIG)*RRN(IIG)*RDY(JJG)*RDZ(KKG)
   ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)

   CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(IIG,JJG,KKG))
   H_G = CP*TMP(IIG,JJG,KKG)

   DO NS=1,N_TRACKED_SPECIES
      IF (ABS(ONE_D%MASSFLUX(NS))<=TWO_EPSILON_EB) CYCLE
      MW_RATIO = SPECIES_MIXTURE(NS)%RCON/RSUM(IIG,JJG,KKG)
      M_DOT_PPP_SINGLE = LP%PWT*ONE_D%MASSFLUX(NS)*ONE_D%AREA*RVC
      LP%M_DOT = ONE_D%MASSFLUX(NS)*ONE_D%AREA
      ZZ_GET=0._EB
      IF (NS>0) ZZ_GET(NS)=1._EB
      CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR,TMP(IIG,JJG,KKG))
      CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CPBAR2,LP%ONE_D%TMP_F)
      DELTA_H_G = CPBAR2*LP%ONE_D%TMP_F-CPBAR*TMP(IIG,JJG,KKG)
      D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) + M_DOT_PPP_SINGLE*(MW_RATIO + DELTA_H_G/H_G)/RHOP(IIG,JJG,KKG)
      M_DOT_PPP(IIG,JJG,KKG,NS) = M_DOT_PPP(IIG,JJG,KKG,NS) + M_DOT_PPP_SINGLE
   ENDDO

   ! Calculate contribution to divergence term due to convective heat transfer from particle

   D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) - ONE_D%QCONF*ONE_D%AREA*RVC/(RHO(IIG,JJG,KKG)*H_G) * LP%PWT

   ! Calculate the mass flux of fuel gas from particles

   I_FUEL = 0
   IF (N_REACTIONS>0) I_FUEL = REACTION(1)%FUEL_SMIX_INDEX

   IF (CORRECTOR) THEN
      IF (I_FUEL>0) &
      M_DOT(2,NM) = M_DOT(2,NM) +     ONE_D%MASSFLUX(I_FUEL)*ONE_D%AREA*LP%PWT
      M_DOT(4,NM) = M_DOT(4,NM) + SUM(ONE_D%MASSFLUX)       *ONE_D%AREA*LP%PWT
   ENDIF

   ! Calculate particle mass

   CALC_LP_MASS:IF (SF%THERMALLY_THICK) THEN
      SELECT CASE (SF%GEOMETRY)
         CASE (SURF_CARTESIAN)
            LP%MASS = 2._EB*SF%LENGTH*SF%WIDTH*SF%THICKNESS*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
          CASE (SURF_CYLINDRICAL)
            LP%MASS = SF%LENGTH*PI*(SF%INNER_RADIUS+SF%THICKNESS)**2*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
         CASE (SURF_SPHERICAL)
            LP%MASS = FOTHPI*(SF%INNER_RADIUS+SF%THICKNESS)**3*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
      END SELECT
   ENDIF CALC_LP_MASS

ENDDO PARTICLE_LOOP

! Loop through the wall cells, apply mass boundary conditions

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC => WALL(IW)

   IF (WC%BOUNDARY_TYPE==OPEN_BOUNDARY)         CYCLE WALL_CELL_LOOP
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY)         CYCLE WALL_CELL_LOOP
   IF (WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE WALL_CELL_LOOP

   ONE_D => WC%ONE_D
   SF => SURFACE(WC%SURF_INDEX)
   II  = ONE_D%II
   JJ  = ONE_D%JJ
   KK  = ONE_D%KK
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG

   CALL CALC_SPECIES_BC(WALL_INDEX=IW)

   ! Only set species mass fraction in the ghost cell if it is not solid

   IF (IW<=N_EXTERNAL_WALL_CELLS .AND. .NOT.SOLID(CELL_INDEX(II,JJ,KK)) .AND. .NOT.SOLID(CELL_INDEX(IIG,JJG,KKG))) &
       ZZP(II,JJ,KK,1:N_TRACKED_SPECIES) = 2._EB*WC%ZZ_F(1:N_TRACKED_SPECIES) - ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)

ENDDO WALL_CELL_LOOP

CONTAINS

SUBROUTINE CALC_SPECIES_BC(WALL_INDEX,PARTICLE_INDEX)

USE HVAC_ROUTINES, ONLY : DUCT_MF
USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT, GET_REALIZABLE_MF
USE MATH_FUNCTIONS, ONLY : EVALUATE_RAMP, BOX_MULLER
REAL(EB) :: ZZ_G,UN,DD,MFT,TSI,ZZ_GET(1:N_TRACKED_SPECIES),RSUM_F,MPUA_SUM,T_IGN,AREA_ADJUST,RHO_0,RN1,RN2,TWOMFT
INTEGER :: N,ITER
INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX,PARTICLE_INDEX

! Special cases for N_TRACKED_SPECIES==1

IF (N_TRACKED_SPECIES==1) THEN

   IF ( WC%NODE_INDEX < 0 .AND. .NOT.SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX ) THEN
      WC%ZZ_F(1) = 1._EB
      RETURN
   ENDIF

   IF ( SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX .AND. ABS(SF%MASS_FLUX(1))<=TWO_EPSILON_EB ) THEN
      WC%ZZ_F(1) = 1._EB
      RETURN
   ENDIF

ENDIF

! Set a few common parameters

T_IGN = ONE_D%T_IGN
AREA_ADJUST = ONE_D%AREA_ADJUST

! Check if suppression by water is to be applied and sum water on surface

IF (PRESENT(WALL_INDEX) .AND. CORRECTOR .AND. SF%E_COEFFICIENT>0._EB .AND. I_WATER>0) THEN
   IF (SPECIES_MIXTURE(I_WATER)%EVAPORATING) THEN
      MPUA_SUM = 0._EB
      DO N=1,N_LAGRANGIAN_CLASSES
         LPC=>LAGRANGIAN_PARTICLE_CLASS(N)
         IF (LPC%Z_INDEX==I_WATER) MPUA_SUM = MPUA_SUM + WC%LP_MPUA(LPC%ARRAY_INDEX)
      ENDDO
      WC%EW = WC%EW + SF%E_COEFFICIENT*MPUA_SUM*DT
   ENDIF
ENDIF

! Get SPECIES_BC_INDEX and adjust for HVAC

IF (WC%NODE_INDEX > 0) THEN
   IF(-DUCTNODE(WC%NODE_INDEX)%DIR(1)*DUCT_MF(DUCTNODE(WC%NODE_INDEX)%DUCT_INDEX(1),1)>=0._EB) THEN
      SPECIES_BC_INDEX = SPECIFIED_MASS_FRACTION
   ELSE
      SPECIES_BC_INDEX = SPECIFIED_MASS_FLUX
   ENDIF
ELSE
   SPECIES_BC_INDEX = SF%SPECIES_BC_INDEX
ENDIF

! Apply the different species boundary conditions to non-thermally thick solids

METHOD_OF_MASS_TRANSFER: SELECT CASE(SPECIES_BC_INDEX)

   CASE (INFLOW_OUTFLOW_MASS_FLUX) METHOD_OF_MASS_TRANSFER

      ! OPEN boundary species BC is done in THERMAL_BC under INFLOW_OUTFLOW

   CASE (NO_MASS_FLUX) METHOD_OF_MASS_TRANSFER

      IF (.NOT.SOLID(CELL_INDEX(IIG,JJG,KKG)) .AND. PRESENT(WALL_INDEX)) &
         WC%ZZ_F(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)

   CASE (SPECIFIED_MASS_FRACTION) METHOD_OF_MASS_TRANSFER

      IF (ABS(T_IGN-T_BEGIN)<SPACING(T_IGN) .AND. ANY(SF%RAMP_INDEX>=1)) THEN
         IF (PREDICTOR) TSI = T + DT
         IF (CORRECTOR) TSI = T
      ELSE
         IF (PREDICTOR) TSI = T + DT - T_IGN
         IF (CORRECTOR) TSI = T      - T_IGN
      ENDIF

      IF (ONE_D%UWS<=0._EB) THEN
         DO N=2,N_TRACKED_SPECIES
            ZZ_GET(N) = SPECIES_MIXTURE(N)%ZZ0 + EVALUATE_RAMP(TSI,SF%TAU(N),SF%RAMP_INDEX(N))* &
                           (SF%MASS_FRACTION(N)-SPECIES_MIXTURE(N)%ZZ0)
         ENDDO
         ZZ_GET(1) = 1._EB-SUM(ZZ_GET(2:N_TRACKED_SPECIES))
         CALL GET_REALIZABLE_MF(ZZ_GET)
         WC%ZZ_F = ZZ_GET
      ELSE
         WC%ZZ_F(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
      ENDIF

   CASE (SPECIFIED_MASS_FLUX) METHOD_OF_MASS_TRANSFER

      ! If the current time is before the "activation" time, T_IGN, apply simple BCs and get out

      IF (T < T_IGN .OR. INITIALIZATION_PHASE) THEN
         IF (.NOT.SOLID(CELL_INDEX(IIG,JJG,KKG)) .AND. PRESENT(WALL_INDEX)) THEN
            WC%ZZ_F(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
         ENDIF
         IF (PREDICTOR) ONE_D%UWS = 0._EB
         IF (CORRECTOR) ONE_D%UW  = 0._EB
         ONE_D%MASSFLUX(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
         RETURN
      ENDIF

      ! Zero out the running counter of Mass Flux Total (MFT)

      MFT = 0._EB

      ! If the user has specified the burning rate, evaluate the ramp and other related parameters

      SUM_MASSFLUX_LOOP: DO N=1,N_TRACKED_SPECIES
         IF (ABS(SF%MASS_FLUX(N)) > TWO_EPSILON_EB) THEN  ! Use user-specified ramp-up of mass flux
            IF (ABS(T_IGN-T_BEGIN) < SPACING(ONE_D%T_IGN) .AND. SF%RAMP_INDEX(N)>=1) THEN
               IF (PREDICTOR) TSI = T + DT
               IF (CORRECTOR) TSI = T
            ELSE
               IF (PREDICTOR) TSI = T + DT - T_IGN
               IF (CORRECTOR) TSI = T      - T_IGN
            ENDIF
            ONE_D%MASSFLUX(N) = EVALUATE_RAMP(TSI,SF%TAU(N),SF%RAMP_INDEX(N))*SF%MASS_FLUX(N)
            ONE_D%MASSFLUX_ACTUAL(N) = ONE_D%MASSFLUX(N)
            ONE_D%MASSFLUX(N) = SF%ADJUST_BURN_RATE(N)*ONE_D%MASSFLUX(N)*AREA_ADJUST
         ENDIF
         MFT = MFT + ONE_D%MASSFLUX(N)
      ENDDO SUM_MASSFLUX_LOOP

      ! Apply user-specified mass flux variation

      IF (SF%MASS_FLUX_VAR > TWO_EPSILON_EB) THEN
         ! generate pairs of standard Gaussian random variables
         CALL BOX_MULLER(RN1,RN2)
         TWOMFT = 2._EB*MFT
         MFT = MFT*(1._EB + RN1*SF%MASS_FLUX_VAR)
         MFT = MAX(0._EB,MIN(TWOMFT,MFT))
      ENDIF

      ! Convection-diffusion boundary condition at a solid wall cell

      IF (PRESENT(WALL_INDEX)) THEN

         IF (WC%EW>TWO_EPSILON_EB) THEN
            ONE_D%MASSFLUX(1:N_TRACKED_SPECIES) = ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)*EXP(-WC%EW)
            ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES) = ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES)*EXP(-WC%EW)
         ENDIF

         ! Add total consumed mass to various summing arrays

         CONSUME_MASS: IF (CORRECTOR .AND. SF%THERMALLY_THICK) THEN
            DO N=1,N_TRACKED_SPECIES
               OBSTRUCTION(WC%OBST_INDEX)%MASS = OBSTRUCTION(WC%OBST_INDEX)%MASS - ONE_D%MASSFLUX_ACTUAL(N)*DT*WC%AW
            ENDDO
         ENDIF CONSUME_MASS

         ! Compute the cell face value of the species mass fraction to get the right mass flux

         RHO_0 = WC%RHO_F
         IF (N_TRACKED_SPECIES==1) THEN
            WC%RHO_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM0*WC%ONE_D%TMP_F)
            WC%ZZ_F(1) = 1._EB
            UN = MFT/WC%RHO_F
         ELSE
            DO ITER=1,3
               UN = MFT/WC%RHO_F
               SPECIES_LOOP: DO N=1,N_TRACKED_SPECIES
                  ZZ_G = ZZP(IIG,JJG,KKG,N)
                  WC%RHODW(N) = WC%RHODW(N)*WC%RHO_F/RHO_0
                  DD = 2._EB*WC%RHODW(N)*WC%RDN
                  DENOM = DD + UN*WC%RHO_F
                  IF ( ABS(DENOM) > TWO_EPSILON_EB ) THEN
                     WC%ZZ_F(N) = ( ONE_D%MASSFLUX(N) + DD*ZZ_G ) / DENOM
                  ELSE
                     WC%ZZ_F(N) = ZZ_G
                  ENDIF
               ENDDO SPECIES_LOOP
               CALL GET_REALIZABLE_MF(WC%ZZ_F)
               ZZ_GET(1:N_TRACKED_SPECIES) = WC%ZZ_F(1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
               RHO_0 = WC%RHO_F
               WC%RHO_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM_F*WC%ONE_D%TMP_F)
            ENDDO
         ENDIF
         IF (PREDICTOR) ONE_D%UWS = -UN
         IF (CORRECTOR) ONE_D%UW  = -UN
      ENDIF

END SELECT METHOD_OF_MASS_TRANSFER

END SUBROUTINE CALC_SPECIES_BC

END SUBROUTINE SPECIES_BC


SUBROUTINE DENSITY_BC

! Compute density at wall from wall temperatures and mass fractions

USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),RSUM_F
INTEGER  :: IW,II,JJ,KK,IIG,JJG,KKG
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE (WALL_TYPE), POINTER :: WC=>NULL()

IF (VEG_LEVEL_SET) RETURN

IF (PREDICTOR) THEN
   PBAR_P => PBAR_S
   RHOP => RHOS
   ZZP  => ZZS
ELSE
   PBAR_P => PBAR
   RHOP => RHO
   ZZP  => ZZ
ENDIF

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC => WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE WALL_CELL_LOOP

   ! Determine face value of RSUM=R0*Sum(Y_i/W_i)

   ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,WC%ZZ_F(1:N_TRACKED_SPECIES))
   CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)

   ! Compute density at boundary cell face

   IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) THEN
      KK = WC%ONE_D%KK
      WC%RHO_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM_F*WC%ONE_D%TMP_F)
      IF (IW<=N_EXTERNAL_WALL_CELLS .AND. WC%BOUNDARY_TYPE/=OPEN_BOUNDARY) THEN
         II = WC%ONE_D%II
         JJ = WC%ONE_D%JJ
         IIG = WC%ONE_D%IIG
         JJG = WC%ONE_D%JJG
         KKG = WC%ONE_D%KKG
         RHOP(II,JJ,KK) = 2._EB*WC%RHO_F - RHOP(IIG,JJG,KKG)
      ENDIF
   ENDIF

ENDDO WALL_CELL_LOOP

END SUBROUTINE DENSITY_BC


SUBROUTINE HVAC_BC

! Compute density at wall from wall temperatures and mass fractions

USE HVAC_ROUTINES, ONLY : NODE_AREA_EX,NODE_TMP_EX,DUCT_MF,NODE_ZZ_EX
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_AVERAGE_SPECIFIC_HEAT
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),UN,MFT,RSUM_F,CP_D,CP_G
INTEGER  :: IIG,JJG,KKG,IW,KK,SURF_INDEX,COUNTER,DU
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (WALL_TYPE),POINTER :: WC=>NULL()

IF (PREDICTOR) THEN
   RHOP => RHOS
   ZZP => ZZS
   PBAR_P => PBAR_S
ELSE
   RHOP => RHO
   ZZP => ZZ
   PBAR_P => PBAR
ENDIF

! Loop over all internal and external wall cells

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC=>WALL(IW)
   IF (WC%NODE_INDEX == 0) CYCLE WALL_CELL_LOOP
   SURF_INDEX = WC%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   KK  = WC%ONE_D%KK
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   COUNTER = 0

   ! Compute R*Sum(Y_i/W_i) at the wall

   DU=DUCTNODE(WC%NODE_INDEX)%DUCT_INDEX(1)
   MFT = -DUCTNODE(WC%NODE_INDEX)%DIR(1)*DUCT_MF(DU,1)/NODE_AREA_EX(WC%NODE_INDEX,1)
   IF (.NOT. ANY(SF%LEAK_PATH>0)) THEN
      IF (DUCTNODE(WC%NODE_INDEX)%DIR(1)*DUCT_MF(DU,1) > 0._EB) THEN
         IF (SF%THERMAL_BC_INDEX==HVAC_BOUNDARY) THEN
            WC%ONE_D%TMP_F = NODE_TMP_EX(WC%NODE_INDEX,1)
            WC%ONE_D%HEAT_TRANS_COEF = 0._EB
            WC%ONE_D%QCONF = 0._EB
         ELSE
            IF (DUCT(DU)%LEAK_ENTHALPY) THEN
               ZZ_GET(1:N_TRACKED_SPECIES) = NODE_ZZ_EX(WC%NODE_INDEX,1:N_TRACKED_SPECIES,1)
               CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CP_G,TMP(IIG,JJG,KKG))
               CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET,CP_D,NODE_TMP_EX(WC%NODE_INDEX,1))
               WC%Q_LEAK = -MFT*(CP_D*NODE_TMP_EX(WC%NODE_INDEX,1)-CP_G*TMP(IIG,JJG,KKG))*WC%RDN
            ENDIF
         ENDIF
      ELSE
         IF (SF%THERMAL_BC_INDEX==HVAC_BOUNDARY) THEN
            WC%ONE_D%TMP_F = TMP(IIG,JJG,KKG)
            WC%ONE_D%HEAT_TRANS_COEF = 0._EB
            WC%ONE_D%QCONF = 0._EB
         ENDIF
      ENDIF
   ENDIF

   IF (MFT >= 0._EB) THEN
      ZZ_GET = ZZP(IIG,JJG,KKG,:)
      CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
      WC%RHO_F = PBAR_P(KK,WC%PRESSURE_ZONE)/(RSUM_F*WC%ONE_D%TMP_F)
      UN = MFT/WC%RHO_F
      IF (PREDICTOR) WC%ONE_D%UWS = UN
      IF (CORRECTOR) WC%ONE_D%UW  = UN
   ELSE
      WC%ONE_D%MASSFLUX(1:N_TRACKED_SPECIES) = -NODE_ZZ_EX(WC%NODE_INDEX,1:N_TRACKED_SPECIES,1)*MFT
   ENDIF
ENDDO WALL_CELL_LOOP

END SUBROUTINE HVAC_BC


SUBROUTINE GEOM_BC

! Apply boundary conditions from unstructured geometry (under construction)

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_HEAT
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
INTEGER :: N,IC,IIG,JJG,KKG
REAL(EB) :: VC
TYPE(FACET_TYPE), POINTER :: FC=>NULL()
TYPE(CUTCELL_LINKED_LIST_TYPE), POINTER :: CL=>NULL()
TYPE(SURFACE_TYPE), POINTER :: SF=>NULL()

IF (PREDICTOR) THEN
   RHOP => RHOS
   ZZP  => ZZS
ELSE
   RHOP => RHO
   ZZP  => ZZ
ENDIF

FACE_LOOP: DO N=1,N_FACE

   FC=>FACET(N)
   CL=>FC%CUTCELL_LIST
   SF=>SURFACE(FC%SURF_INDEX)

   CUTCELL_LOOP: DO

      IF ( .NOT. ASSOCIATED(CL) ) EXIT CUTCELL_LOOP ! if the next index does not exist, exit the loop

      IC = CL%INDEX
      IIG = I_CUTCELL(IC)
      JJG = J_CUTCELL(IC)
      KKG = K_CUTCELL(IC)
      VC = DX(IIG)*DY(JJG)*DZ(KKG)

      FC%TMP_G = TMP(IIG,JJG,KKG)

      CL=>CL%NEXT ! point to the next index in the linked list

   ENDDO CUTCELL_LOOP

ENDDO FACE_LOOP

END SUBROUTINE GEOM_BC


SUBROUTINE ZETA_BC

INTEGER :: IW,II,JJ,KK,IIG,JJG,KKG,IOR
REAL(EB) :: UN
LOGICAL :: INFLOW
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(SURFACE_TYPE), POINTER :: SF=>NULL()

IF (PREDICTOR) THEN
   ZZP=>ZZS
ELSE
   ZZP=>ZZ
ENDIF

! Loop through the wall cells, apply zeta boundary conditions

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC => WALL(IW)
   SF => SURFACE(WC%SURF_INDEX)
   II  = WC%ONE_D%II
   JJ  = WC%ONE_D%JJ
   KK  = WC%ONE_D%KK
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   IOR = WC%ONE_D%IOR

   BOUNDARY_TYPE_SELECT: SELECT CASE(WC%BOUNDARY_TYPE)

      CASE DEFAULT

         WC%ZZ_F(ZETA_INDEX) = INITIAL_UNMIXED_FRACTION

      CASE(SOLID_BOUNDARY)

         WC%ZZ_F(ZETA_INDEX) = SF%ZETA_FRONT

      CASE(OPEN_BOUNDARY)

         INFLOW = .FALSE.
         SELECT CASE(IOR)
            CASE( 1); UN = U(II,JJ,KK)
            CASE(-1); UN = -U(II-1,JJ,KK)
            CASE( 2); UN = V(II,JJ,KK)
            CASE(-2); UN = -V(II,JJ-1,KK)
            CASE( 3); UN = W(II,JJ,KK)
            CASE(-3); UN = -W(II,JJ,KK-1)
         END SELECT
         IF (UN>TWO_EPSILON_EB) INFLOW = .TRUE.

         IF (INFLOW) THEN
            WC%ZZ_F(ZETA_INDEX)=INITIAL_UNMIXED_FRACTION
         ELSE
            WC%ZZ_F(ZETA_INDEX)=ZZP(IIG,JJG,KKG,ZETA_INDEX)
         ENDIF
         ZZP(II,JJ,KK,ZETA_INDEX) = WC%ZZ_F(ZETA_INDEX) ! Ghost cell values

      CASE(INTERPOLATED_BOUNDARY)

         ! handled in SPECIES_BC

   END SELECT BOUNDARY_TYPE_SELECT

   ! Only set ghost cell if it is not solid

   IF (IW<=N_EXTERNAL_WALL_CELLS .AND. .NOT.SOLID(CELL_INDEX(II,JJ,KK)) .AND. .NOT.SOLID(CELL_INDEX(IIG,JJG,KKG))) &
       ZZP(II,JJ,KK,ZETA_INDEX) = WC%ZZ_F(ZETA_INDEX)

ENDDO WALL_CELL_LOOP


END SUBROUTINE ZETA_BC


SUBROUTINE PYROLYSIS(NM,T,DT_BC,PARTICLE_INDEX,WALL_INDEX)

! Loop through all the boundary cells that require a 1-D heat transfer calc

USE PHYSICAL_FUNCTIONS, ONLY: GET_MOLECULAR_WEIGHT, GET_MASS_FRACTION, GET_VISCOSITY
USE GEOMETRY_FUNCTIONS
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP,INTERPOLATE1D_UNIFORM
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
REAL(EB), INTENT(IN) :: DT_BC,T
INTEGER, INTENT(IN) :: NM
INTEGER, INTENT(IN), OPTIONAL:: WALL_INDEX,PARTICLE_INDEX
REAL(EB) :: DUMMY,DTMP,QDXKF,QDXKB,RR,TMP_G,RFACF,RFACB,RFACF2,RFACB2, &
            DXKF,DXKB,REACTION_RATE,QRADINB,RFLUX_UP,RFLUX_DOWN,E_WALLB, &
            MFLUX, MFLUX_S, VOLSUM, REGRID_MAX, REGRID_SUM,  &
            DXF, DXB,HTCB,Q_WATER_F,Q_WATER_B,TMP_F_OLD, RHO_S0,DT2_BC,TOLERANCE,LAYER_DIVIDE,&
            MW_G,H_MASS,X_G,Y_G,X_W,D_AIR,MU_AIR,U2,V2,W2,RE_L,SC_AIR,SH_FAC_WALL,SHERWOOD,VELCON,RHO_G,TMP_BACK,RDN
INTEGER :: IIG,JJG,KKG,IIB,JJB,KKB,IWB,NWP,KK,I,J,NR,NN,NNN,NL,IOR,N,I_OBST,NS,N_LAYER_CELLS_NEW(MAX_LAYERS),N_CELLS
REAL(EB) :: SMALLEST_CELL_SIZE(MAX_LAYERS),THICKNESS,ZZ_GET(1:N_TRACKED_SPECIES)
REAL(EB),ALLOCATABLE,DIMENSION(:) :: TMP_W_NEW
REAL(EB),ALLOCATABLE,DIMENSION(:,:) :: INT_WGT
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOG=>NULL()
REAL(EB), POINTER, DIMENSION(:,:) :: PBARP
REAL(EB), POINTER :: TMP_F,TMP_B,T_IGN
INTEGER  :: NWP_NEW,I_GRAD,STEPCOUNT,SMIX_PTR,IZERO,SURF_INDEX
LOGICAL :: REMESH,ITERATE,E_FOUND
CHARACTER(MESSAGE_LENGTH) :: MESSAGE
TYPE (WALL_TYPE), POINTER :: WC=>NULL(),WALL_P
TYPE (LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP=>NULL()
TYPE (ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D=>NULL()
TYPE (SURFACE_TYPE), POINTER :: SF=>NULL()
TYPE (MATERIAL_TYPE), POINTER :: ML=>NULL()

! Copy commonly used derived type variables into local variables.

UNPACK_WALL_PARTICLE: IF (PRESENT(WALL_INDEX)) THEN

   WC => WALL(WALL_INDEX)
   SURF_INDEX = WC%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   ONE_D => WC%ONE_D
   IOR = WC%ONE_D%IOR
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   KK  = WC%ONE_D%KK
   TMP_F => ONE_D%TMP_F
   TMP_B => ONE_D%TMP_B
   T_IGN => ONE_D%T_IGN
   I_OBST = WC%OBST_INDEX
   IWB = WC%BACK_INDEX
   RDN = WC%RDN

   ! Take away energy flux due to water evaporation

   IF (NLP>0) THEN
      Q_WATER_F  = -SUM(WC%LP_CPUA(:))
   ELSE
      Q_WATER_F  = 0._EB
   ENDIF

ELSEIF (PRESENT(PARTICLE_INDEX)) THEN UNPACK_WALL_PARTICLE

   LP => LAGRANGIAN_PARTICLE(PARTICLE_INDEX)
   ONE_D => LP%ONE_D
   SURF_INDEX = LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   KK  = ONE_D%KKG
   IOR = ONE_D%IOR
   TMP_F => ONE_D%TMP_F
   TMP_B => ONE_D%TMP_B
   T_IGN => ONE_D%T_IGN
   I_OBST = 0
   IWB = -1
   IF (IOR==0) THEN
      RDN = (RDX(IIG)*RDY(JJG)*RDZ(KKG))**ONTH
   ELSE
      SELECT CASE (ABS(IOR))
         CASE (1)
            RDN = RDX(IIG)
         CASE (2)
            RDN = RDY(JJG)
         CASE (3)
            RDN = RDZ(KKG)
      END SELECT
   ENDIF

   Q_WATER_F  = 0._EB

ENDIF UNPACK_WALL_PARTICLE

! Compute convective heat flux at the surface

TMP_G = TMP(IIG,JJG,KKG)
IF (ASSUMED_GAS_TEMPERATURE > 0._EB) TMP_G = TMPA + EVALUATE_RAMP(T-T_BEGIN,DUMMY,I_RAMP_AGT)*(ASSUMED_GAS_TEMPERATURE-TMPA)
TMP_F_OLD = TMP_F
DTMP = TMP_G - TMP_F_OLD
IF (PRESENT(WALL_INDEX)) THEN
   ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                     SF%ROUGHNESS,SURF_INDEX,WALL_INDEX=WALL_INDEX)
ELSE
   ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SF%GEOMETRY,SF%CONV_LENGTH,SF%HEAT_TRANSFER_MODEL,&
                                                     SF%ROUGHNESS,SURF_INDEX,PARTICLE_INDEX=PARTICLE_INDEX)
ENDIF
ONE_D%QCONF = ONE_D%HEAT_TRANS_COEF*DTMP

! Set pointers

IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   RHOG => RHO
   PBARP => PBAR
ELSE
   UU => US
   VV => VS
   WW => WS
   RHOG => RHOS
   PBARP => PBAR_S
ENDIF

! Miscellaneous coefficients

SC_AIR = 0.6_EB     ! NU_AIR/D_AIR (Incropera & DeWitt, Chap 7, External Flow)
SH_FAC_WALL = 0.037_EB*SC_AIR**ONTH

! Exponents for cylindrical or spherical coordinates

SELECT CASE(SF%GEOMETRY)
CASE(SURF_CARTESIAN)
   I_GRAD = 1
CASE(SURF_CYLINDRICAL)
   I_GRAD = 2
CASE(SURF_SPHERICAL)
   I_GRAD = 3
END SELECT

! Compute back side emissivity

E_WALLB = SF%EMISSIVITY_BACK
IF (E_WALLB < 0._EB .AND. SF%BACKING /= INSULATED) THEN
   E_WALLB = 0._EB
   VOLSUM = 0._EB
   IF (SF%PYROLYSIS_MODEL==PYROLYSIS_MATERIAL) THEN
      NWP = SUM(ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS))
   ELSE
      NWP = SF%N_CELLS_INI
   ENDIF
   DO N=1,SF%N_MATL
      IF (ONE_D%RHO(NWP,N)<=TWO_EPSILON_EB) CYCLE
      ML => MATERIAL(SF%MATL_INDEX(N))
      VOLSUM = VOLSUM + ONE_D%RHO(NWP,N)/ML%RHO_S
      E_WALLB = E_WALLB + ONE_D%RHO(NWP,N)*ML%EMISSIVITY/ML%RHO_S
   ENDDO
   IF (VOLSUM > 0._EB) E_WALLB = E_WALLB/VOLSUM
ENDIF

! Get heat losses from convection and radiation out of back of surface

LAYER_DIVIDE = SF%LAYER_DIVIDE

SELECT CASE(SF%BACKING)

   CASE(VOID)  ! Non-insulated backing to an ambient void

      IF (SF%TMP_BACK>0._EB) THEN
         TMP_BACK = SF%TMP_BACK
      ELSE
         TMP_BACK = TMP_0(KK)
      ENDIF
      DTMP = TMP_BACK - TMP_B
      HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SF%GEOMETRY,SF%CONV_LENGTH,HT_MODEL=0,ROUGHNESS=0._EB,&
                                       SURF_INDEX=SURF_INDEX,WALL_INDEX=-1)
      QRADINB   =  E_WALLB*SIGMA*TMP_BACK**4
      Q_WATER_B = 0._EB

   CASE(INSULATED)  ! No heat transfer out the back

      HTCB      = 0._EB
      QRADINB   = 0._EB
      E_WALLB   = 0._EB
      Q_WATER_B = 0._EB
      IF (SF%TMP_BACK>0._EB) THEN
         TMP_BACK = SF%TMP_BACK
      ELSE
         TMP_BACK = TMP_0(KK)
      ENDIF

   CASE(EXPOSED)  ! The backside is exposed to gas in current or adjacent mesh.

      Q_WATER_B = 0._EB

      SELECT CASE(IWB)

         CASE(1:) ! Solid backing

            IF (WC%BACK_MESH/=NM .AND. WC%BACK_MESH>0) THEN  ! Back side is in other mesh.
               TMP_BACK = OMESH(WC%BACK_MESH)%EXPOSED_WALL(IWB)%TMP_GAS
               DTMP = TMP_BACK - TMP_B
               HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SF%GEOMETRY,SF%CONV_LENGTH,HT_MODEL=0,ROUGHNESS=0._EB, &
                                                SURF_INDEX=SURF_INDEX)
               QRADINB  = OMESH(WC%BACK_MESH)%EXPOSED_WALL(IWB)%QRADIN
            ELSE  ! Back side is in current mesh.
               WALL_P => WALL(IWB)
               IIB = WALL_P%ONE_D%IIG
               JJB = WALL_P%ONE_D%JJG
               KKB = WALL_P%ONE_D%KKG
               TMP_BACK  = TMP(IIB,JJB,KKB)
               DTMP = TMP_BACK - TMP_B
               HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SF%GEOMETRY,SF%CONV_LENGTH,HT_MODEL=0,ROUGHNESS=0._EB, &
                                                SURF_INDEX=SURF_INDEX,WALL_INDEX=IWB)
               WALL_P%ONE_D%HEAT_TRANS_COEF = HTCB
               QRADINB  = WALL_P%ONE_D%QRADIN
               IF (NLP>0) Q_WATER_B = -SUM(WALL_P%LP_CPUA(:))
            ENDIF

         CASE DEFAULT  ! The back side is an ambient void.

            TMP_BACK = TMP_0(KK)
            DTMP = TMP_BACK - TMP_B
            HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SF%GEOMETRY,SF%CONV_LENGTH,HT_MODEL=0,ROUGHNESS=0._EB, &
                                             SURF_INDEX=SURF_INDEX,WALL_INDEX=-1)
            QRADINB  =  E_WALLB*SIGMA*TMP_BACK**4
            LAYER_DIVIDE = REAL(SF%N_LAYERS+1)

         CASE(-1) ! Particle "backside conditions" are assumed to be from the same gas cell

            TMP_BACK  = TMP(IIG,JJG,KKG)
            DTMP = TMP_BACK - TMP_B
            HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SF%GEOMETRY,SF%CONV_LENGTH,HT_MODEL=0,ROUGHNESS=0._EB, &
                                          SURF_INDEX=SURF_INDEX,PARTICLE_INDEX=PARTICLE_INDEX)
            QRADINB  = ONE_D%QRADIN

      END SELECT

END SELECT

! Compute grid for reacting nodes

COMPUTE_GRID: IF (SF%PYROLYSIS_MODEL==PYROLYSIS_MATERIAL) THEN
   NWP = SUM(ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS))
   CALL GET_WALL_NODE_WEIGHTS(NWP,SF%N_LAYERS,ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS),ONE_D%LAYER_THICKNESS,SF%GEOMETRY, &
      ONE_D%X(0:NWP),LAYER_DIVIDE,DX_S(1:NWP),RDX_S(0:NWP+1),RDXN_S(0:NWP),DX_WGT_S(0:NWP),DXF,DXB,&
      LAYER_INDEX(0:NWP+1),MF_FRAC(1:NWP),SF%INNER_RADIUS)
ELSE COMPUTE_GRID
   NWP                  = SF%N_CELLS_INI
   DXF                  = SF%DXF
   DXB                  = SF%DXB
   DX_S(1:NWP)          = SF%DX(1:NWP)
   RDX_S(0:NWP+1)       = SF%RDX(0:NWP+1)
   RDXN_S(0:NWP)        = SF%RDXN(0:NWP)
   DX_WGT_S(0:NWP)      = SF%DX_WGT(0:NWP)
   LAYER_INDEX(0:NWP+1) = SF%LAYER_INDEX(0:NWP+1)
   MF_FRAC(1:NWP)       = SF%MF_FRAC(1:NWP)
ENDIF COMPUTE_GRID

! Get total thickness of solid and compute radius for cylindrical and spherical coordinate systems.

THICKNESS = SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))

DO I=0,NWP
   R_S(I) = SF%INNER_RADIUS + ONE_D%X(NWP) - ONE_D%X(I)
ENDDO

! Calculate reaction rates based on the solid phase reactions

REMESH = .FALSE.
Q_S = 0._EB
PYROLYSIS_MATERIAL_IF: IF (SF%PYROLYSIS_MODEL==PYROLYSIS_MATERIAL) THEN

   ! Set mass fluxes to 0 and CHANGE_THICKNESS to false.

   ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)        = 0._EB
   ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
   ONE_D%CHANGE_THICKNESS                     = .FALSE.

   POINT_LOOP1: DO I=1,NWP

      RHO_S0 = SF%LAYER_DENSITY(LAYER_INDEX(I))
      REGRID_FACTOR(I) = 1._EB
      REGRID_MAX       = 0._EB
      REGRID_SUM       = 0._EB

      MATERIAL_LOOP1a: DO N=1,SF%N_MATL

         IF (ONE_D%RHO(I,N) <= 0._EB) CYCLE MATERIAL_LOOP1a

         ML  => MATERIAL(SF%MATL_INDEX(N))

         LIQUID_OR_SOLID: IF (ML%PYROLYSIS_MODEL==PYROLYSIS_LIQUID) THEN
            IF (I > 1) THEN
               REGRID_SUM = 1._EB
               CYCLE MATERIAL_LOOP1a
            ENDIF
            SMIX_PTR = MAXLOC(ML%NU_GAS(:,1),1)
            ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))
            CALL GET_MOLECULAR_WEIGHT(ZZ_GET,MW_G)
            X_G = ZZ_GET(SMIX_PTR)/SPECIES_MIXTURE(SMIX_PTR)%MW*MW_G
            X_W = MIN(1._EB-TWO_EPSILON_EB,EXP(ML%H_R(1)*SPECIES_MIXTURE(SMIX_PTR)%MW/R0*(1._EB/ML%TMP_BOIL-1._EB/ONE_D%TMP_F)))
            IF (DNS) THEN
               CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z(:,SMIX_PTR),1),D_Z(:,SMIX_PTR),TMP(IIG,JJG,KKG),D_AIR)
               H_MASS = 2._EB*D_AIR*RDN
            ELSE
               CALL GET_VISCOSITY(ZZ_GET,MU_AIR,TMP_G)
               ! Calculate tangential velocity near the surface
               RHO_G = RHOG(IIG,JJG,KKG)
               U2 = 0.25_EB*(UU(IIG,JJG,KKG)+UU(IIG-1,JJG,KKG))**2
               V2 = 0.25_EB*(VV(IIG,JJG,KKG)+VV(IIG,JJG-1,KKG))**2
               W2 = 0.25_EB*(WW(IIG,JJG,KKG)+WW(IIG,JJG,KKG-1))**2
               SELECT CASE(ABS(IOR))
               CASE(1)
                  U2 = 0._EB
               CASE(2)
                  V2 = 0._EB
               CASE(3)
                  W2 = 0._EB
               END SELECT
               VELCON = SQRT(U2+V2+W2)
               RE_L     = MAX(5.E5_EB,RHO_G*VELCON*SF%CONV_LENGTH/MU_AIR)
               SHERWOOD = SH_FAC_WALL*RE_L**0.8_EB
               H_MASS = SHERWOOD*MU_AIR/(RHO(IIG,JJG,KKG)*SC*SF%CONV_LENGTH)
            ENDIF
            IF(SF%HM_FIXED>=0._EB) THEN
               H_MASS=SF%HM_FIXED
            ENDIF
            MFLUX = MAX(0._EB,SPECIES_MIXTURE(SMIX_PTR)%MW/R0/ONE_D%TMP_F*H_MASS*LOG((X_G-1._EB)/(X_W-1._EB)))
            MFLUX = MFLUX * PBARP(KKG,PRESSURE_ZONE(IIG,JJG,KKG))
            MFLUX = MIN(MFLUX,ONE_D%LAYER_THICKNESS(LAYER_INDEX(1))*ML%RHO_S/DT_BC)

            ! CYLINDRICAL and SPHERICAL scaling not implemented
            DO NS = 1,N_TRACKED_SPECIES
               ONE_D%MASSFLUX(NS)        = ONE_D%MASSFLUX(NS)        + ML%ADJUST_BURN_RATE(NS,1)*ML%NU_GAS(NS,1)*MFLUX
               ONE_D%MASSFLUX_ACTUAL(NS) = ONE_D%MASSFLUX_ACTUAL(NS) +                           ML%NU_GAS(NS,1)*MFLUX
            ENDDO
            J = 0
            ! Always remesh for liquid fuels
            IF(MFLUX>TWO_EPSILON_EB) REMESH=.TRUE.
            DO WHILE (MFLUX > 0._EB)
               J = J + 1
               MFLUX_S = MIN(MFLUX,DX_S(J)*ML%RHO_S/DT_BC)
               Q_S(1) = Q_S(1) - MFLUX_S*ML%H_R(1)/DX_S(J)
               ONE_D%RHO(J,N) = MAX( 0._EB , ONE_D%RHO(J,N) - DT_BC*MFLUX_S/DX_S(J) )
               MFLUX = MFLUX-MFLUX_S
            ENDDO
         ELSE LIQUID_OR_SOLID ! solid phase reactions
            REACTION_LOOP: DO J=1,ML%N_REACTIONS
               ! Reaction rate in 1/s
               REACTION_RATE = ML%A(J)*(ONE_D%RHO(I,N)/RHO_S0)**ML%N_S(J)*EXP(-ML%E(J)/(R0*ONE_D%TMP(I)))
               ! power term
               DTMP = ML%THR_SIGN(J)*(ONE_D%TMP(I)-ML%TMP_THR(J))
               IF (ABS(ML%N_T(J))>=TWO_EPSILON_EB) THEN
                  IF (DTMP > 0._EB) THEN
                     REACTION_RATE = REACTION_RATE * DTMP**ML%N_T(J)
                  ELSE
                     REACTION_RATE = 0._EB
                  ENDIF
               ELSE ! threshold
                  IF (DTMP < 0._EB) REACTION_RATE = 0._EB
               ENDIF
               ! Phase change reaction?
               IF (ML%PCR(J)) THEN
                  REACTION_RATE = REACTION_RATE / ((ABS(ML%H_R(J))/1000._EB) * DT_BC)
               ENDIF
               ! Oxidation reaction?
               IF ( (ML%N_O2(J)>0._EB) .AND. (O2_INDEX > 0)) THEN
                  ! Get oxygen mass fraction
                  ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))
                  CALL GET_MASS_FRACTION(ZZ_GET,O2_INDEX,Y_G)
                  ! Calculate oxygen volume fraction in the gas cell
                  X_G = SPECIES(O2_INDEX)%RCON*Y_G/RSUM(IIG,JJG,KKG)
                  ! Calculate oxygen concentration inside the material, assuming decay function
                  X_G = X_G * EXP(-ONE_D%X(I-1)/(EPSILON_EB+ML%GAS_DIFFUSION_DEPTH(J)))
                  REACTION_RATE = REACTION_RATE * X_G**ML%N_O2(J)
               ENDIF
               ! Reaction rate in kg/(m3s)
               REACTION_RATE = RHO_S0 * REACTION_RATE
               ! Limit reaction rate
               REACTION_RATE = MIN(REACTION_RATE , ONE_D%RHO(I,N)/DT_BC)
               ! Compute mdot''_norm
               MFLUX_S = MF_FRAC(I)*REACTION_RATE*(R_S(I-1)**I_GRAD-R_S(I)**I_GRAD)/ &
                         (I_GRAD*(SF%INNER_RADIUS+SF%THICKNESS)**(I_GRAD-1))
               ! Sum up local mass fluxes
               DO NS = 1,N_TRACKED_SPECIES
                  ONE_D%MASSFLUX(NS)        = ONE_D%MASSFLUX(NS)        + ML%ADJUST_BURN_RATE(NS,J)*ML%NU_GAS(NS,J)*MFLUX_S
                  ONE_D%MASSFLUX_ACTUAL(NS) = ONE_D%MASSFLUX_ACTUAL(NS) +                           ML%NU_GAS(NS,J)*MFLUX_S
               ENDDO
               Q_S(I) = Q_S(I) - REACTION_RATE * ML%H_R(J)
               ONE_D%RHO(I,N) = MAX( 0._EB , ONE_D%RHO(I,N) - DT_BC*REACTION_RATE )
               DO NN=1,ML%N_RESIDUE(J)
                  IF (ML%NU_RESIDUE(NN,J) > 0._EB ) THEN
                     NNN = SF%RESIDUE_INDEX(N,NN,J)
                     ONE_D%RHO(I,NNN) = ONE_D%RHO(I,NNN) + ML%NU_RESIDUE(NN,J)*DT_BC*REACTION_RATE
                  ENDIF
               ENDDO
            ENDDO REACTION_LOOP
         ENDIF LIQUID_OR_SOLID

         REGRID_MAX = MAX(REGRID_MAX,ONE_D%RHO(I,N)/ML%RHO_S)
         REGRID_SUM = REGRID_SUM + ONE_D%RHO(I,N)/ML%RHO_S

      ENDDO MATERIAL_LOOP1a

      IF (REGRID_SUM <= 1._EB) REGRID_FACTOR(I) = REGRID_SUM
      IF (REGRID_MAX >= ALMOST_ONE) REGRID_FACTOR(I) = REGRID_MAX

      ! If there is any non-shrinking material, the material matrix will remain, and no shrinking is allowed

      MATERIAL_LOOP1b: DO N=1,SF%N_MATL
         IF (ONE_D%RHO(I,N)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP1b
         ML  => MATERIAL(SF%MATL_INDEX(N))
         IF (.NOT. ML%ALLOW_SHRINKING) THEN
            REGRID_FACTOR(I) = MAX(REGRID_FACTOR(I),1._EB)
            EXIT MATERIAL_LOOP1b
         ENDIF
      ENDDO MATERIAL_LOOP1b

      ! If there is any non-swelling material, the material matrix will remain, and no swelling is allowed

      MATERIAL_LOOP1c: DO N=1,SF%N_MATL
         IF (ONE_D%RHO(I,N)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP1c
         ML  => MATERIAL(SF%MATL_INDEX(N))
         IF (.NOT. ML%ALLOW_SWELLING) THEN
            REGRID_FACTOR(I) = MIN(REGRID_FACTOR(I),1._EB)
            EXIT MATERIAL_LOOP1c
         ENDIF
      ENDDO MATERIAL_LOOP1c

      ! In points that change thickness, update the density

      IF (ABS(REGRID_FACTOR(I)-1._EB)>=TWO_EPSILON_EB) THEN
         ONE_D%CHANGE_THICKNESS=.TRUE.
         MATERIAL_LOOP1d: DO N=1,SF%N_MATL
            IF(REGRID_FACTOR(I)>TWO_EPSILON_EB) ONE_D%RHO(I,N) = ONE_D%RHO(I,N)/REGRID_FACTOR(I)
         ENDDO MATERIAL_LOOP1d
      ENDIF

   ENDDO POINT_LOOP1

   ! Adjust the MASSFLUX of a wall surface cell to account for non-alignment of the mesh.

   IF (PRESENT(WALL_INDEX)) ONE_D%MASSFLUX(1:N_TRACKED_SPECIES) = ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)*ONE_D%AREA_ADJUST

   ! Compute new coordinates if the solid changes thickness. Save new coordinates in X_S_NEW.

   R_S_NEW(NWP) = 0._EB
   DO I=NWP-1,0,-1
      R_S_NEW(I) = ( R_S_NEW(I+1)**I_GRAD + (R_S(I)**I_GRAD-R_S(I+1)**I_GRAD)*REGRID_FACTOR(I+1) )**(1./REAL(I_GRAD))
   ENDDO

   X_S_NEW(0) = 0._EB
   DO I=1,NWP
      X_S_NEW(I) = R_S_NEW(0) - R_S_NEW(I)
      IF ((X_S_NEW(I)-X_S_NEW(I-1)) < TWO_EPSILON_EB) REMESH = .TRUE.
   ENDDO

   ! If the fuel or water massflux is non-zero, set the ignition time

   IF (T_IGN > T) THEN
      IF (SUM(ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)) > 0._EB) T_IGN = T
   ENDIF

   ! Re-generate grid for a wall changing thickness

   N_LAYER_CELLS_NEW = 0
   SMALLEST_CELL_SIZE = 0._EB

   REMESH_GRID: IF (ONE_D%CHANGE_THICKNESS) THEN
      NWP_NEW = 0
      THICKNESS = 0._EB

      I = 0
      LAYER_LOOP: DO NL=1,SF%N_LAYERS

         ONE_D%LAYER_THICKNESS(NL) = X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL)) - X_S_NEW(I)

         ! Remove very thin layers

         IF (ONE_D%LAYER_THICKNESS(NL) < SF%MINIMUM_LAYER_THICKNESS) THEN
            X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL):NWP) = X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL):NWP)-ONE_D%LAYER_THICKNESS(NL)
            ONE_D%LAYER_THICKNESS(NL) = 0._EB
            N_LAYER_CELLS_NEW(NL) = 0
         ELSE
            CALL GET_N_LAYER_CELLS(SF%MIN_DIFFUSIVITY(NL),ONE_D%LAYER_THICKNESS(NL), &
               SF%STRETCH_FACTOR(NL),SF%CELL_SIZE_FACTOR,SF%N_LAYER_CELLS_MAX(NL),N_LAYER_CELLS_NEW(NL),SMALLEST_CELL_SIZE(NL))
            NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)
         ENDIF
         IF ( N_LAYER_CELLS_NEW(NL) /= ONE_D%N_LAYER_CELLS(NL)) REMESH = .TRUE.

         THICKNESS = THICKNESS + ONE_D%LAYER_THICKNESS(NL)
         I = I + ONE_D%N_LAYER_CELLS(NL)
      ENDDO LAYER_LOOP

      ! Check that NWP_NEW has not exceeded the allocated space N_CELLS_MAX
      IF (NWP_NEW > SF%N_CELLS_MAX) THEN
         WRITE(MESSAGE,'(A,I5,A,A)') 'ERROR: N_CELLS_MAX should be at least ',NWP_NEW,' for surface ',TRIM(SF%ID)
         CALL SHUTDOWN(MESSAGE)
      ENDIF

      ! Shrinking wall has gone to zero thickness.
      IF (THICKNESS <=TWO_EPSILON_EB) THEN
         ONE_D%TMP(0:NWP+1)    = MAX(TMPMIN,TMP_BACK)
         TMP_F            = MIN(TMPMAX,MAX(TMPMIN,TMP_BACK))
         TMP_B            = MIN(TMPMAX,MAX(TMPMIN,TMP_BACK))
         ONE_D%QCONF            = 0._EB
         ONE_D%MASSFLUX(1:N_TRACKED_SPECIES)  = 0._EB
         ONE_D%MASSFLUX_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS)     = 0
         ONE_D%BURNAWAY          = .TRUE.
         IF (I_OBST > 0) THEN
            IF (OBSTRUCTION(I_OBST)%CONSUMABLE) OBSTRUCTION(I_OBST)%MASS = -1.
         ENDIF
         RETURN
      ENDIF

      ! Set up new node points following shrinking/swelling

      ONE_D%X(0:NWP) = X_S_NEW(0:NWP)

      X_S_NEW = 0._EB
      IF (REMESH) THEN
         CALL GET_WALL_NODE_COORDINATES(NWP_NEW,SF%N_LAYERS,N_LAYER_CELLS_NEW, &
            SMALLEST_CELL_SIZE(1:SF%N_LAYERS),SF%STRETCH_FACTOR(1:SF%N_LAYERS),X_S_NEW(0:NWP_NEW))
         CALL GET_WALL_NODE_WEIGHTS(NWP_NEW,SF%N_LAYERS,N_LAYER_CELLS_NEW,ONE_D%LAYER_THICKNESS,SF%GEOMETRY, &
            X_S_NEW(0:NWP_NEW),LAYER_DIVIDE,DX_S(1:NWP_NEW),RDX_S(0:NWP_NEW+1),RDXN_S(0:NWP_NEW),&
            DX_WGT_S(0:NWP_NEW),DXF,DXB,LAYER_INDEX(0:NWP_NEW+1),MF_FRAC(1:NWP_NEW),SF%INNER_RADIUS)
         ! Interpolate densities and temperature from old grid to new grid
         ALLOCATE(INT_WGT(NWP_NEW,NWP),STAT=IZERO)
         CALL GET_INTERPOLATION_WEIGHTS(SF%N_LAYERS,NWP,NWP_NEW,ONE_D%N_LAYER_CELLS,N_LAYER_CELLS_NEW, &
                                    ONE_D%X(0:NWP),X_S_NEW(0:NWP_NEW),INT_WGT)
         N_CELLS = MAX(NWP,NWP_NEW)
         CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,ONE_D%TMP(1:N_CELLS))
         ONE_D%TMP(0) = 2*TMP_F-ONE_D%TMP(1) !Make sure surface temperature stays the same
         ONE_D%TMP(NWP_NEW+1) = ONE_D%TMP(NWP+1)
         CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,Q_S(1:N_CELLS))
         DO N=1,SF%N_MATL
            ML  => MATERIAL(SF%MATL_INDEX(N))
            CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,ONE_D%RHO(1:N_CELLS,N))
         ENDDO
         DEALLOCATE(INT_WGT)
         ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS) = N_LAYER_CELLS_NEW(1:SF%N_LAYERS)
         NWP = NWP_NEW
         ONE_D%X(0:NWP) = X_S_NEW(0:NWP)      ! Note: X(NWP+1...) are not set to zero.
      ELSE
         CALL GET_WALL_NODE_WEIGHTS(NWP,SF%N_LAYERS,N_LAYER_CELLS_NEW,ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS),SF%GEOMETRY, &
            ONE_D%X(0:NWP),LAYER_DIVIDE,DX_S(1:NWP),RDX_S(0:NWP+1),RDXN_S(0:NWP),DX_WGT_S(0:NWP),DXF,DXB, &
            LAYER_INDEX(0:NWP+1),MF_FRAC(1:NWP),SF%INNER_RADIUS)
      ENDIF

   ENDIF REMESH_GRID

ELSEIF (SF%PYROLYSIS_MODEL==PYROLYSIS_SPECIFIED) THEN PYROLYSIS_MATERIAL_IF

   ! Take off energy corresponding to specified burning rate

   Q_S(1) = Q_S(1) - ONE_D%MASSFLUX(REACTION(1)%FUEL_SMIX_INDEX)*SF%H_V/DX_S(1)

ENDIF PYROLYSIS_MATERIAL_IF

! Calculate thermal properties

K_S     = 0._EB
RHO_S   = 0._EB
RHOCBAR = 0._EB
ONE_D%EMISSIVITY = 0._EB
E_FOUND = .FALSE.

POINT_LOOP3: DO I=1,NWP
   VOLSUM = 0._EB
   MATERIAL_LOOP3: DO N=1,SF%N_MATL
      IF (ONE_D%RHO(I,N)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP3
      ML  => MATERIAL(SF%MATL_INDEX(N))
      VOLSUM = VOLSUM + ONE_D%RHO(I,N)/ML%RHO_S
      IF (ML%K_S>0._EB) THEN
         K_S(I) = K_S(I) + ONE_D%RHO(I,N)*ML%K_S/ML%RHO_S
      ELSE
         NR = -NINT(ML%K_S)
         K_S(I) = K_S(I) + ONE_D%RHO(I,N)*EVALUATE_RAMP(ONE_D%TMP(I),0._EB,NR)/ML%RHO_S
      ENDIF

      IF (ML%C_S>0._EB) THEN
         RHOCBAR(I) = RHOCBAR(I) + ONE_D%RHO(I,N)*ML%C_S
      ELSE
         NR = -NINT(ML%C_S)
         RHOCBAR(I) = RHOCBAR(I) + ONE_D%RHO(I,N)*EVALUATE_RAMP(ONE_D%TMP(I),0._EB,NR)
      ENDIF
      IF (.NOT.E_FOUND) ONE_D%EMISSIVITY = ONE_D%EMISSIVITY + ONE_D%RHO(I,N)*ML%EMISSIVITY/ML%RHO_S
      RHO_S(I) = RHO_S(I) + ONE_D%RHO(I,N)

   ENDDO MATERIAL_LOOP3

   IF (VOLSUM > 0._EB) THEN
      K_S(I) = K_S(I)/VOLSUM
      IF (.NOT.E_FOUND) ONE_D%EMISSIVITY = ONE_D%EMISSIVITY/VOLSUM
   ENDIF
   IF (ONE_D%EMISSIVITY>0._EB) E_FOUND = .TRUE.

   IF (K_S(I)<=TWO_EPSILON_EB)      K_S(I)      = 10000._EB
   IF (RHOCBAR(I)<=TWO_EPSILON_EB)  RHOCBAR(I)  = 0.001_EB

ENDDO POINT_LOOP3

! Calculate average K_S between at grid cell boundaries. Store result in K_S

K_S(0)     = K_S(1)
K_S(NWP+1) = K_S(NWP)
DO I=1,NWP-1
   K_S(I)  = 1._EB / ( DX_WGT_S(I)/K_S(I) + (1._EB-DX_WGT_S(I))/K_S(I+1) )
ENDDO

! Add internal heat source specified by user

IF (SF%SPECIFIED_HEAT_SOURCE) THEN
   DO I=1,NWP
      Q_S(I) = Q_S(I)+SF%INTERNAL_HEAT_SOURCE(LAYER_INDEX(I))
   ENDDO
ENDIF

! Calculate internal radiation

IF (SF%INTERNAL_RADIATION) THEN
   KAPPA_S = 0._EB
   DO I=1,NWP
      VOLSUM = 0._EB
      DO N=1,SF%N_MATL
         IF (ONE_D%RHO(I,N)<=TWO_EPSILON_EB) CYCLE
         ML  => MATERIAL(SF%MATL_INDEX(N))
         VOLSUM = VOLSUM + ONE_D%RHO(I,N)/ML%RHO_S
         KAPPA_S(I) = KAPPA_S(I) + ONE_D%RHO(I,N)*ML%KAPPA_S/ML%RHO_S
      ENDDO
      IF (VOLSUM>0._EB) KAPPA_S(I) = 2._EB*KAPPA_S(I)/(RDX_S(I)*VOLSUM)    ! kappa = 2*dx*kappa or 2*r*dr*kappa
   ENDDO
   DO I=0,NWP
      IF (SF%GEOMETRY==SURF_CYLINDRICAL) THEN
         R_S(I) = SF%INNER_RADIUS+SF%THICKNESS-SF%X_S(I)
      ELSE
         R_S(I) = 1._EB
      ENDIF
   ENDDO
   ! solution inwards
   RFLUX_UP = ONE_D%QRADIN + (1._EB-ONE_D%EMISSIVITY)*ONE_D%QRADOUT/(ONE_D%EMISSIVITY+1.0E-10_EB)
   DO I=1,NWP
      RFLUX_DOWN =  ( R_S(I-1)*RFLUX_UP + KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (R_S(I) + KAPPA_S(I))
      Q_S(I) = Q_S(I) + (R_S(I-1)*RFLUX_UP - R_S(I)*RFLUX_DOWN)*RDX_S(I)
      RFLUX_UP = RFLUX_DOWN
   ENDDO
   ! solution outwards
   RFLUX_UP = QRADINB + (1._EB-E_WALLB)*RFLUX_UP
   DO I=NWP,1,-1
      RFLUX_DOWN =  ( R_S(I)*RFLUX_UP + KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (R_S(I-1) + KAPPA_S(I))
      Q_S(I) = Q_S(I) + (R_S(I)*RFLUX_UP - R_S(I-1)*RFLUX_DOWN)*RDX_S(I)
      RFLUX_UP = RFLUX_DOWN
   ENDDO
   ONE_D%QRADOUT = ONE_D%EMISSIVITY*RFLUX_DOWN
ENDIF

! Update the 1-D heat transfer equation

DT2_BC = DT_BC
STEPCOUNT = 1
ALLOCATE(TMP_W_NEW(0:NWP+1),STAT=IZERO)
TMP_W_NEW(0:NWP+1) = ONE_D%TMP(0:NWP+1)
WALL_ITERATE: DO
   ITERATE=.FALSE.
   SUB_TIME: DO N=1,STEPCOUNT
      DXKF   = K_S(0)/DXF
      DXKB   = K_S(NWP)/DXB
      DO I=1,NWP
         BBS(I) = -0.5_EB*DT2_BC*K_S(I-1)*RDXN_S(I-1)*RDX_S(I)/RHOCBAR(I) ! DT_BC->DT2_BC
         AAS(I) = -0.5_EB*DT2_BC*K_S(I)  *RDXN_S(I)  *RDX_S(I)/RHOCBAR(I)
      ENDDO
      DDS(1:NWP) = 1._EB - AAS(1:NWP) - BBS(1:NWP)
      DO I=1,NWP
         CCS(I) = TMP_W_NEW(I) - AAS(I)*(TMP_W_NEW(I+1)-TMP_W_NEW(I)) + BBS(I)*(TMP_W_NEW(I)-TMP_W_NEW(I-1)) &
                  + DT2_BC*Q_S(I)/RHOCBAR(I)
      ENDDO
      IF (.NOT. RADIATION .OR. SF%INTERNAL_RADIATION) THEN
         RFACF = 0.25_EB*ONE_D%HEAT_TRANS_COEF
         RFACB = 0.25_EB*HTCB
      ELSE
         RFACF = 0.25_EB*ONE_D%HEAT_TRANS_COEF + 2._EB*ONE_D%EMISSIVITY*SIGMA*TMP_F**3
         RFACB = 0.25_EB*HTCB + 2._EB*E_WALLB*SIGMA*TMP_B**3
      ENDIF
      RFACF2 = (DXKF-RFACF)/(DXKF+RFACF)
      RFACB2 = (DXKB-RFACB)/(DXKB+RFACB)
      IF (.NOT. RADIATION .OR. SF%INTERNAL_RADIATION) THEN
         QDXKF = (ONE_D%HEAT_TRANS_COEF*(TMP_G    - 0.5_EB*TMP_F) + Q_WATER_F)/(DXKF+RFACF)
         QDXKB = (HTCB*                 (TMP_BACK - 0.5_EB*TMP_B) + Q_WATER_B)/(DXKB+RFACB)
      ELSE
         QDXKF = (ONE_D%HEAT_TRANS_COEF*(TMP_G - 0.5_EB*TMP_F) + ONE_D%QRADIN + 3.*ONE_D%EMISSIVITY*SIGMA*TMP_F**4 + Q_WATER_F) &
               /(DXKF+RFACF)
         QDXKB = (HTCB*(TMP_BACK - 0.5_EB*TMP_B) + QRADINB + 3.*E_WALLB*SIGMA*TMP_B**4 + Q_WATER_B) &
               /(DXKB+RFACB)
      ENDIF
      CCS(1)   = CCS(1)   - BBS(1)  *QDXKF
      CCS(NWP) = CCS(NWP) - AAS(NWP)*QDXKB
      DDT(1:NWP) = DDS(1:NWP)
      DDT(1)   = DDT(1)   + BBS(1)  *RFACF2
      DDT(NWP) = DDT(NWP) + AAS(NWP)*RFACB2
      TRIDIAGONAL_SOLVER_1: DO I=2,NWP
         RR     = BBS(I)/DDT(I-1)
         DDT(I) = DDT(I) - RR*AAS(I-1)
         CCS(I) = CCS(I) - RR*CCS(I-1)
      ENDDO TRIDIAGONAL_SOLVER_1
      CCS(NWP)  = CCS(NWP)/DDT(NWP)
      TRIDIAGONAL_SOLVER_2: DO I=NWP-1,1,-1
         CCS(I) = (CCS(I) - AAS(I)*CCS(I+1))/DDT(I)
      ENDDO TRIDIAGONAL_SOLVER_2
      TMP_W_NEW(1:NWP) = MAX(TMPMIN,CCS(1:NWP))
      TMP_W_NEW(0)     = MAX(TMPMIN,TMP_W_NEW(1)  *RFACF2+QDXKF)
      TMP_W_NEW(NWP+1) = MAX(TMPMIN,TMP_W_NEW(NWP)*RFACB2+QDXKB)
      IF (STEPCOUNT==1) THEN
         TOLERANCE = MAXVAL(ABS((TMP_W_NEW-ONE_D%TMP(0:NWP+1))/ONE_D%TMP(0:NWP+1)), &
            ONE_D%TMP(0:NWP+1)>0._EB) ! returns a negative number, if all TMP_S == 0.
         IF (TOLERANCE<0.0_EB) &
         TOLERANCE = MAXVAL(ABS((TMP_W_NEW-ONE_D%TMP(0:NWP+1))/TMP_W_NEW), &
            TMP_W_NEW>0._EB)
         IF (TOLERANCE > 0.2_EB) THEN
            STEPCOUNT = MIN(200,STEPCOUNT * (INT(TOLERANCE/0.2_EB) + 1))
            ITERATE=.TRUE.
            DT2_BC=DT_BC/REAL(STEPCOUNT)
            TMP_W_NEW = ONE_D%TMP(0:NWP+1)
         ENDIF
      ENDIF
      IF (NWP == 1) THEN
         TMP_F = TMP_W_NEW(1)
         TMP_B = TMP_F
      ELSE
         TMP_F  = 0.5_EB*(TMP_W_NEW(0)+TMP_W_NEW(1))
         TMP_B  = 0.5_EB*(TMP_W_NEW(NWP)+TMP_W_NEW(NWP+1))
      ENDIF
      TMP_F  = MIN(TMPMAX,MAX(TMPMIN,TMP_F))
      TMP_B  = MIN(TMPMAX,MAX(TMPMIN,TMP_B))
   ENDDO SUB_TIME
   IF (.NOT. ITERATE) EXIT WALL_ITERATE
ENDDO WALL_ITERATE

ONE_D%TMP(0:NWP+1) = TMP_W_NEW
DEALLOCATE(TMP_W_NEW)

! If the surface temperature exceeds the ignition temperature, burn it

IF (T_IGN > T ) THEN
   IF (TMP_F >= SF%TMP_IGN) T_IGN = T
ENDIF

! Determine convective heat flux at the wall

ONE_D%QCONF = ONE_D%HEAT_TRANS_COEF * (TMP_G - 0.5_EB * (TMP_F + TMP_F_OLD) )

END SUBROUTINE PYROLYSIS


REAL(EB) FUNCTION HEAT_TRANSFER_COEFFICIENT(DELTA_TMP,H_FIXED,GEOMETRY,CONV_LENGTH,HT_MODEL,ROUGHNESS,SURF_INDEX,&
                                            WALL_INDEX,PARTICLE_INDEX,FACE_INDEX,CUTCELL_INDEX)

! Compute the convective heat transfer coefficient

USE TURBULENCE, ONLY: HEAT_FLUX_MODEL,ABL_HEAT_FLUX_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_CONDUCTIVITY,GET_VISCOSITY,GET_SPECIFIC_HEAT
REAL(EB), INTENT(IN) :: DELTA_TMP,H_FIXED,CONV_LENGTH,ROUGHNESS
INTEGER, INTENT(IN) :: SURF_INDEX
INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX,PARTICLE_INDEX,FACE_INDEX,CUTCELL_INDEX
INTEGER  :: IIG,JJG,KKG,IOR,GEOMETRY,HT_MODEL,ITMP
REAL(EB) :: RE,U2,V2,W2,H_NATURAL,H_FORCED,NUSSELT,VELCON,FRICTION_VELOCITY,YPLUS,RHO_G,TMP_G,TMP_F,DN,TMP_FILM,MU_G,K_G,CP_G, &
            ZZ_GET(1:N_TRACKED_SPECIES)
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW,RHOP
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB), PARAMETER :: EPS=1.E-10_EB
TYPE(LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP
TYPE(ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D
TYPE(WALL_TYPE), POINTER :: WC
TYPE(FACET_TYPE), POINTER :: FC
TYPE(SURFACE_TYPE), POINTER :: SF

! If the user wants a specified HTC, set it and return

IF (H_FIXED >= 0._EB) THEN
   HEAT_TRANSFER_COEFFICIENT = H_FIXED
   RETURN
ENDIF

SF => SURFACE(SURF_INDEX)

! Determine if this is a particle or wall cell

IF (PRESENT(PARTICLE_INDEX)) THEN
   LP    => LAGRANGIAN_PARTICLE(PARTICLE_INDEX)
   ONE_D => LP%ONE_D
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   IOR = ONE_D%IOR
   TMP_F = ONE_D%TMP_F
   DN = CONV_LENGTH
ELSEIF (PRESENT(WALL_INDEX)) THEN
   IF (WALL_INDEX<=0) THEN
      HEAT_TRANSFER_COEFFICIENT = SF%C_VERTICAL*ABS(DELTA_TMP)**ONTH
      RETURN
   ENDIF
   WC    => WALL(WALL_INDEX)
   ONE_D => WALL(WALL_INDEX)%ONE_D
   IIG = ONE_D%IIG
   JJG = ONE_D%JJG
   KKG = ONE_D%KKG
   IOR = ONE_D%IOR
   SELECT CASE(IOR)
      CASE( 1); IF (IIG>IBAR) THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
      CASE(-1); IF (IIG<1)    THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
      CASE( 2); IF (JJG>JBAR) THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
      CASE(-2); IF (JJG<1)    THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
      CASE( 3); IF (KKG>KBAR) THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
      CASE(-3); IF (KKG<1)    THEN; HEAT_TRANSFER_COEFFICIENT=0._EB; RETURN; ENDIF
   END SELECT
   FRICTION_VELOCITY = WC%U_TAU
   YPLUS = WC%Y_PLUS
   TMP_F = ONE_D%TMP_F
   DN = 1._EB/WC%RDN
ELSEIF (PRESENT(FACE_INDEX).AND.PRESENT(CUTCELL_INDEX)) THEN
   FC => FACET(FACE_INDEX)
   IIG = I_CUTCELL(CUTCELL_INDEX)
   JJG = J_CUTCELL(CUTCELL_INDEX)
   KKG = K_CUTCELL(CUTCELL_INDEX)
   IOR = 0
   FRICTION_VELOCITY = FC%U_TAU
   YPLUS = FC%Y_PLUS
   TMP_F = FC%TMP_F
   DN = 1._EB/FC%RDN
ELSE
   HEAT_TRANSFER_COEFFICIENT = 0._EB
   RETURN
ENDIF

! If this is a DNS calculation at a solid wall, set HTC and return.

IF (DNS .AND. PRESENT(WALL_INDEX)) THEN
   HEAT_TRANSFER_COEFFICIENT = 2._EB*WC%KW*WC%RDN
   RETURN
ENDIF

IF (DNS .AND. PRESENT(FACE_INDEX)) THEN
   HEAT_TRANSFER_COEFFICIENT = 2._EB*FC%KW*FC%RDN
   RETURN
ENDIF

! Get velocities, etc.

IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   RHOP => RHOS
   ZZP => ZZS
ELSE
   UU => US
   VV => VS
   WW => WS
   RHOP => RHO
   ZZP => ZZ
ENDIF

RHO_G = RHOP(IIG,JJG,KKG)
TMP_G = TMP(IIG,JJG,KKG)

IF (PRESENT(PARTICLE_INDEX)) THEN
   U2 = 0.25_EB*(UU(IIG,JJG,KKG)+UU(IIG-1,JJG,KKG)-2._EB*LP%U)**2
   V2 = 0.25_EB*(VV(IIG,JJG,KKG)+VV(IIG,JJG-1,KKG)-2._EB*LP%V)**2
   W2 = 0.25_EB*(WW(IIG,JJG,KKG)+WW(IIG,JJG,KKG-1)-2._EB*LP%W)**2
   VELCON = SQRT(U2+V2+W2)
ELSEIF (PRESENT(WALL_INDEX)) THEN
   U2 = 0.25_EB*(UU(IIG,JJG,KKG)+UU(IIG-1,JJG,KKG))**2
   V2 = 0.25_EB*(VV(IIG,JJG,KKG)+VV(IIG,JJG-1,KKG))**2
   W2 = 0.25_EB*(WW(IIG,JJG,KKG)+WW(IIG,JJG,KKG-1))**2
   VELCON = SQRT(U2+V2+W2)
ELSEIF (PRESENT(FACE_INDEX)) THEN
   VELCON = SQRT(2._EB*KRES(IIG,JJG,KKG))
ENDIF

! Calculate the HTC for natural/free convection (Holman, 1990, Table 7-2)

SELECT CASE(GEOMETRY)
   CASE (SURF_CARTESIAN)
      SELECT CASE(ABS(IOR))
         CASE(0:2)
            H_NATURAL = SF%C_VERTICAL*ABS(DELTA_TMP)**ONTH
         CASE(3)
            H_NATURAL = SF%C_HORIZONTAL*ABS(DELTA_TMP)**ONTH
         END SELECT

   CASE (SURF_CYLINDRICAL)
      H_NATURAL = SF%C_VERTICAL*ABS(DELTA_TMP)**ONTH

   CASE (SURF_SPHERICAL) ! It is assumed that the forced HTC represents natural convection as well
      H_NATURAL = 0._EB
END SELECT

! Calculate the HTC for forced convection

TMP_FILM = 0.5_EB*(TMP_G+TMP_F)
ITMP = MIN(4999,NINT(TMP_FILM))

ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)

HTC_MODEL_SELECT: SELECT CASE(HT_MODEL)
   CASE DEFAULT
      CALL GET_VISCOSITY(ZZ_GET,MU_G,TMP_FILM)
      CALL GET_CONDUCTIVITY(ZZ_GET,K_G,TMP_FILM)
      RE = RHO_G*VELCON*CONV_LENGTH/MU_G
      SELECT CASE(GEOMETRY)
         CASE (SURF_CARTESIAN)
            ! Incropera and DeWitt, 3rd, 1990, Eq. 7.44
            NUSSELT = 0.037_EB*RE**0.8_EB*PR_ONTH
         CASE (SURF_CYLINDRICAL)
            ! Incropera and DeWitt, 3rd, 1990, Eq. 7.55, 40 < Re < 4000
            NUSSELT = 0.683_EB*RE**0.466_EB*PR_ONTH
         CASE (SURF_SPHERICAL)
            ! Incropera and DeWitt, 3rd, 1990, Eq. 7.59
            NUSSELT = 2._EB + 0.6_EB*SQRT(RE)*PR_ONTH
      END SELECT
      H_FORCED  = NUSSELT*K_G/CONV_LENGTH
   CASE(H_LOGLAW)
      H_NATURAL = 0._EB
      CALL GET_VISCOSITY(ZZ_GET,MU_G,TMP_FILM)
      CALL GET_CONDUCTIVITY(ZZ_GET,K_G,TMP_FILM)
      CALL GET_SPECIFIC_HEAT(ZZ_GET,CP_G,TMP_FILM)
      CALL HEAT_FLUX_MODEL(H_FORCED,YPLUS,FRICTION_VELOCITY,K_G,RHO_G,CP_G,MU_G)
   CASE(H_ABL)
      H_NATURAL = 0._EB
      CALL GET_SPECIFIC_HEAT(ZZ_GET,CP_G,TMP_FILM)
      CALL ABL_HEAT_FLUX_MODEL(H_FORCED,FRICTION_VELOCITY,DN,ROUGHNESS,TMP_G,TMP_F,RHO_G,CP_G)
   CASE(H_EDDY)
      H_NATURAL = 0._EB
      CALL GET_SPECIFIC_HEAT(ZZ_GET,CP_G,TMP_FILM)
      H_FORCED = MU(IIG,JJG,KKG)*CP_G/PR * (2._EB/DN)
   CASE(H_CUSTOM)
      CALL GET_VISCOSITY(ZZ_GET,MU_G,TMP_FILM)
      CALL GET_CONDUCTIVITY(ZZ_GET,K_G,TMP_FILM)
      RE = RHO_G*VELCON*CONV_LENGTH/MU_G
      NUSSELT = SF%C_FORCED_CONSTANT+SF%C_FORCED_RE*RE**SF%C_FORCED_RE_EXP*PR_AIR**SF%C_FORCED_PR_EXP
      H_FORCED = NUSSELT*K_G/CONV_LENGTH
END SELECT HTC_MODEL_SELECT

HEAT_TRANSFER_COEFFICIENT = MAX(H_FORCED,H_NATURAL)

END FUNCTION HEAT_TRANSFER_COEFFICIENT

END MODULE WALL_ROUTINES

